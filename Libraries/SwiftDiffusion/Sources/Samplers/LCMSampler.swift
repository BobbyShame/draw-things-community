import Foundation
import NNC

public struct LCMSampler<
  FloatType: TensorNumeric & BinaryFloatingPoint, UNet: UNetProtocol,
  Discretization: Denoiser.Discretization
>
where UNet.FloatType == FloatType {
  public let filePath: String
  public let modifier: SamplerModifier
  public let version: ModelVersion
  public let usesFlashAttention: Bool
  public let upcastAttention: Bool
  public let externalOnDemand: Bool
  public let injectControls: Bool
  public let injectT2IAdapters: Bool
  public let injectIPAdapterLengths: [Int]
  public let lora: [LoRAConfiguration]
  public let is8BitModel: Bool
  public let canRunLoRASeparately: Bool
  public let conditioning: Denoiser.Conditioning
  public let tiledDiffusion: TiledConfiguration
  private let discretization: Discretization
  public init(
    filePath: String, modifier: SamplerModifier, version: ModelVersion, usesFlashAttention: Bool,
    upcastAttention: Bool, externalOnDemand: Bool, injectControls: Bool,
    injectT2IAdapters: Bool, injectIPAdapterLengths: [Int], lora: [LoRAConfiguration],
    is8BitModel: Bool, canRunLoRASeparately: Bool, conditioning: Denoiser.Conditioning,
    tiledDiffusion: TiledConfiguration, discretization: Discretization
  ) {
    self.filePath = filePath
    self.modifier = modifier
    self.version = version
    self.usesFlashAttention = usesFlashAttention
    self.upcastAttention = upcastAttention
    self.externalOnDemand = externalOnDemand
    self.injectControls = injectControls
    self.injectT2IAdapters = injectT2IAdapters
    self.injectIPAdapterLengths = injectIPAdapterLengths
    self.lora = lora
    self.is8BitModel = is8BitModel
    self.canRunLoRASeparately = canRunLoRASeparately
    self.conditioning = conditioning
    self.tiledDiffusion = tiledDiffusion
    self.discretization = discretization
  }
}

extension LCMSampler: Sampler {
  private func scalingsForBoundaryConditionDiscrete(timestep: Int) -> (Float, Float) {
    // let sigmaData = 0.5
    let scaledTimestep = Double(timestep) * 10
    let cSkip = 0.25 / (scaledTimestep * scaledTimestep + 0.25)
    let cOut = scaledTimestep / (scaledTimestep * scaledTimestep + 0.25).squareRoot()
    return (Float(cSkip), Float(cOut))
  }

  public func sample(
    _ x_T: DynamicGraph.Tensor<FloatType>, unets existingUNets: [UNet?],
    sample: DynamicGraph.Tensor<FloatType>?, maskedImage: DynamicGraph.Tensor<FloatType>?,
    depthImage: DynamicGraph.Tensor<FloatType>?,
    mask: DynamicGraph.Tensor<FloatType>?, negMask: DynamicGraph.Tensor<FloatType>?,
    conditioning c: [DynamicGraph.Tensor<FloatType>], tokenLengthUncond: Int, tokenLengthCond: Int,
    extraProjection: DynamicGraph.Tensor<FloatType>?,
    injectedControls: [(
      model: ControlModel<FloatType>, hints: [([DynamicGraph.Tensor<FloatType>], Float)]
    )],
    textGuidanceScale: Float, imageGuidanceScale: Float,
    startStep: (integral: Int, fractional: Float), endStep: (integral: Int, fractional: Float),
    originalSize: (width: Int, height: Int), cropTopLeft: (top: Int, left: Int),
    targetSize: (width: Int, height: Int), aestheticScore: Float,
    negativeOriginalSize: (width: Int, height: Int), negativeAestheticScore: Float,
    zeroNegativePrompt: Bool, refiner: Refiner?, fpsId: Int, motionBucketId: Int, condAug: Float,
    startFrameCfg: Float, sharpness: Float, sampling: Sampling,
    feedback: (Int, Tensor<FloatType>?) -> Bool
  ) -> Result<SamplerOutput<FloatType, UNet>, Error> {
    var x = x_T
    let batchSize = x.shape[0]
    let startHeight = x.shape[1]
    let startWidth = x.shape[2]
    let channels = x.shape[3]
    let graph = x.graph
    let inChannels: Int
    if version == .svdI2v {
      inChannels = channels * 2
    } else {
      switch modifier {
      case .inpainting:
        inChannels = channels * 2 + 1
      case .depth:
        inChannels = channels + 1
      case .editing:
        inChannels = channels * 2
      case .none:
        inChannels = channels
      }
    }
    let zeroNegativePrompt = false
    var xIn = graph.variable(
      .GPU(0), .NHWC(batchSize, startHeight, startWidth, inChannels),
      of: FloatType.self
    )
    switch modifier {
    case .inpainting:
      let maskedImage = maskedImage!
      let mask = mask!
      for i in 0..<batchSize {
        xIn[i..<(i + 1), 0..<startHeight, 0..<startWidth, channels..<(channels + 1)] = mask
        xIn[i..<(i + 1), 0..<startHeight, 0..<startWidth, (channels + 1)..<(channels * 2 + 1)] =
          maskedImage
      }
    case .editing:
      let maskedImage = maskedImage!
      for i in 0..<batchSize {
        xIn[i..<(i + 1), 0..<startHeight, 0..<startWidth, channels..<(channels * 2)] = maskedImage
      }
    case .depth:
      let depthImage = depthImage!
      for i in 0..<batchSize {
        xIn[i..<(i + 1), 0..<startHeight, 0..<startWidth, channels..<(channels + 1)] = depthImage
      }
    case .none:
      break
    }
    var c = c
    var extraProjection = extraProjection
    // There is no tokenLengthUncond any more.
    let tokenLengthUncond = tokenLengthCond
    if version != .svdI2v {
      for i in 0..<c.count {
        let shape = c[i].shape
        if shape.count == 3 {
          let conditionalLength = version == .kandinsky21 ? shape[1] : tokenLengthCond
          // Only tokenLengthCond is used.
          c[i] = c[i][batchSize..<(batchSize * 2), 0..<conditionalLength, 0..<shape[2]].copied()
        } else if shape.count == 2 {
          c[i] = c[i][batchSize..<(batchSize * 2), 0..<shape[1]].copied()
        }
      }
      if var projection = extraProjection {
        let shape = projection.shape
        if shape.count == 3 {
          // Only tokenLengthCond is used.
          projection = projection[batchSize..<(batchSize * 2), 0..<shape[1], 0..<shape[2]].copied()
        } else if shape.count == 2 {
          projection = projection[batchSize..<(batchSize * 2), 0..<shape[1]].copied()
        }
        extraProjection = projection
      }
    }
    let oldC = c
    let fixedEncoder = UNetFixedEncoder<FloatType>(
      filePath: filePath, version: version, usesFlashAttention: usesFlashAttention,
      zeroNegativePrompt: zeroNegativePrompt)
    let injectedControlsC: [[DynamicGraph.Tensor<FloatType>]]
    if c.count >= 2 || version == .svdI2v {
      let vector = fixedEncoder.vector(
        textEmbedding: c[c.count - 1], originalSize: originalSize,
        cropTopLeft: cropTopLeft,
        targetSize: targetSize, aestheticScore: aestheticScore,
        negativeOriginalSize: negativeOriginalSize, negativeAestheticScore: negativeAestheticScore,
        fpsId: fpsId, motionBucketId: motionBucketId, condAug: condAug)
      let (encodings, weightMapper) = fixedEncoder.encode(
        textEncoding: c, timesteps: [], batchSize: batchSize, startHeight: startHeight,
        startWidth: startWidth,
        tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond, lora: lora)
      c = vector + encodings
      injectedControlsC = injectedControls.map {
        $0.model.encode(
          textEncoding: oldC, vector: vector.first, batchSize: batchSize, startHeight: startHeight,
          startWidth: startWidth, tokenLengthUncond: tokenLengthUncond,
          tokenLengthCond: tokenLengthCond, zeroNegativePrompt: zeroNegativePrompt,
          mainUNetFixed: (fixedEncoder.filePath, weightMapper))
      }
    } else {
      injectedControlsC = injectedControls.map {
        $0.model.encode(
          textEncoding: oldC, vector: nil, batchSize: batchSize, startHeight: startHeight,
          startWidth: startWidth, tokenLengthUncond: tokenLengthUncond,
          tokenLengthCond: tokenLengthCond, zeroNegativePrompt: zeroNegativePrompt,
          mainUNetFixed: (fixedEncoder.filePath, nil))
      }
    }
    var unet = existingUNets[0] ?? UNet()
    var controlNets = [Model?](repeating: nil, count: injectedControls.count)
    var timeEmbeddingSize = version == .kandinsky21 || version == .sdxlRefiner ? 384 : 320
    if existingUNets[0] == nil {
      let firstTimestep =
        discretization.timesteps - discretization.timesteps / Float(sampling.steps) + 1
      let t = unet.timeEmbed(
        graph: graph, batchSize: batchSize, timestep: firstTimestep, version: version)
      let (injectedControls, injectedT2IAdapters, injectedIPAdapters) =
        ControlModel<FloatType>
        .emptyInjectedControlsAndAdapters(
          injecteds: injectedControls, step: 0, version: version, inputs: xIn,
          tiledDiffusion: tiledDiffusion)
      let newC: [DynamicGraph.Tensor<FloatType>]
      if version == .svdI2v {
        newC = Array(c[0..<(1 + (c.count - 1) / 2)])
      } else {
        newC = c
      }
      let _ = unet.compileModel(
        filePath: filePath, externalOnDemand: externalOnDemand, version: version,
        upcastAttention: upcastAttention, usesFlashAttention: usesFlashAttention,
        injectControls: injectControls, injectT2IAdapters: injectT2IAdapters,
        injectIPAdapterLengths: injectIPAdapterLengths, lora: lora,
        is8BitModel: is8BitModel, canRunLoRASeparately: canRunLoRASeparately,
        inputs: xIn, t, newC, tokenLengthUncond: tokenLengthUncond,
        tokenLengthCond: tokenLengthCond,
        extraProjection: extraProjection, injectedControls: injectedControls,
        injectedT2IAdapters: injectedT2IAdapters, injectedIPAdapters: injectedIPAdapters,
        tiledDiffusion: tiledDiffusion)
    }
    let alphasCumprod = Array(
      discretization.alphasCumprod(steps: 1000, shift: sampling.shift).reversed())
    let sigmas = alphasCumprod.map { ((1 - $0) / $0).squareRoot() }
    var noise: DynamicGraph.Tensor<FloatType>? = nil
    if mask != nil || version == .kandinsky21 {
      noise = graph.variable(.GPU(0), .NHWC(batchSize, startHeight, startWidth, channels))
    }
    let streamContext = StreamContext(.GPU(0))
    var refinerKickIn = refiner.map { (1 - $0.start) * discretization.timesteps } ?? -1
    var unets: [UNet?] = [unet]
    var timesteps = (0..<sampling.steps).map {
      min(
        Int(
          (Double(1000 - 1 - 20) * Double(sampling.steps - $0)
            / Double(sampling.steps)).rounded()) + 20, 1000 - 1)
    }
    if (Float(startStep.integral) - startStep.fractional).magnitude >= 1e-4 {
      timesteps[startStep.integral] = min(
        Int(
          1000 - startStep.fractional * 1000 / Float(sampling.steps)), 1000 - 1)
    }
    if (Float(endStep.integral) - endStep.fractional).magnitude >= 1e-4
      && endStep.integral < sampling.steps
    {
      timesteps[endStep.integral] = min(
        Int(
          1000 - endStep.fractional * 1000 / Float(sampling.steps)), 1000 - 1)
    }
    let blur: Model?
    if sharpness > 0 {
      blur = Blur(filters: channels, sigma: 3.0, size: 13, input: x)
    } else {
      blur = nil
    }
    var currentModelVersion = version
    let result: Result<SamplerOutput<FloatType, UNet>, Error> = graph.withStream(streamContext) {
      let condProj = Dense(count: 320, noBias: true)
      let cfg = graph.variable(
        Tensor<FloatType>(
          from: guidanceScaleEmbedding(guidanceScale: textGuidanceScale - 1, embeddingSize: 256)
        ).toGPU(0))
      condProj.compile(inputs: cfg)
      graph.openStore(
        filePath, flags: .readOnly, externalStore: TensorData.externalStore(filePath: filePath)
      ) { store in
        store.read("w_cond_proj", model: condProj, codec: [.q6p, .q8p, .ezm7, .externalData]) {
          name, dataType, format, shape in
          guard store.read(name) == nil else {
            return .continue(name)
          }
          switch dataType {
          case .Float16:
            #if !((os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))) && (arch(i386) || arch(x86_64)))
              var tensor = Tensor<Float16>(.CPU, format: format, shape: shape)
              tensor.withUnsafeMutableBytes {
                let size = shape.reduce(MemoryLayout<Float16>.size, *)
                if let baseAddress = $0.baseAddress {
                  memset(baseAddress, 0, size)
                }
              }
              return .final(tensor)
            #else
              return .continue(name)
            #endif
          case .Float32:
            var tensor = Tensor<Float32>(.CPU, format: format, shape: shape)
            tensor.withUnsafeMutableBytes {
              let size = shape.reduce(MemoryLayout<Float32>.size, *)
              if let baseAddress = $0.baseAddress {
                memset(baseAddress, 0, size)
              }
            }
            return .final(tensor)
          case .Float64, .Int32, .Int64, .UInt8:
            fatalError()
          }
        }
      }
      var cfgCond = condProj(inputs: cfg)[0].as(of: FloatType.self)
      if timeEmbeddingSize != cfgCond.shape[1] {
        cfgCond = graph.variable(.GPU(0), .WC(batchSize, timeEmbeddingSize), of: FloatType.self)
        cfgCond.full(0)
      }
      if version == .svdI2v {
        let maskedImage = maskedImage!
        var frames = graph.variable(
          .GPU(0), .NHWC(batchSize, startHeight, startWidth, channels), of: FloatType.self)
        for i in 0..<batchSize {
          frames[i..<(i + 1), 0..<startHeight, 0..<startWidth, 0..<channels] = maskedImage
        }
        if condAug > 0 {
          let noise = graph.variable(like: frames)
          noise.randn(std: condAug)
          frames = frames .+ noise
        }
        xIn[0..<batchSize, 0..<startHeight, 0..<startWidth, channels..<(channels * 2)] = frames
      }
      var oldDenoised: DynamicGraph.Tensor<FloatType>? = nil
      for i in startStep.integral..<endStep.integral {
        let rawValue: Tensor<FloatType>? =
          (i > max(startStep.integral, sampling.steps / 2) || i % 5 == 4)
          ? (oldDenoised.map { unet.decode($0) })?.rawValue.toCPU() : nil
        if i % 5 == 4, let rawValue = rawValue {
          if isNaN(rawValue) {
            return .failure(SamplerError.isNaN)
          }
        }
        guard feedback(i - startStep.integral, rawValue) else {
          return .failure(SamplerError.cancelled)
        }
        let timestep = timesteps[i]
        if Float(timestep) < refinerKickIn, let refiner = refiner {
          unets = [nil]
          let fixedEncoder = UNetFixedEncoder<FloatType>(
            filePath: refiner.filePath, version: refiner.version,
            usesFlashAttention: usesFlashAttention, zeroNegativePrompt: zeroNegativePrompt)
          if oldC.count >= 2 || refiner.version == .svdI2v {
            let vector = fixedEncoder.vector(
              textEmbedding: oldC[oldC.count - 1], originalSize: originalSize,
              cropTopLeft: cropTopLeft,
              targetSize: targetSize, aestheticScore: aestheticScore,
              negativeOriginalSize: negativeOriginalSize,
              negativeAestheticScore: negativeAestheticScore, fpsId: fpsId,
              motionBucketId: motionBucketId, condAug: condAug)
            c =
              vector
              + fixedEncoder.encode(
                textEncoding: oldC, timesteps: [], batchSize: batchSize, startHeight: startHeight,
                startWidth: startWidth, tokenLengthUncond: tokenLengthUncond,
                tokenLengthCond: tokenLengthCond, lora: lora
              ).0
          }
          unet = UNet()
          currentModelVersion = refiner.version
          timeEmbeddingSize =
            refiner.version == .kandinsky21 || refiner.version == .sdxlRefiner ? 384 : 320
          let firstTimestep = timesteps[0]
          let t = unet.timeEmbed(
            graph: graph, batchSize: batchSize, timestep: Float(firstTimestep),
            version: currentModelVersion)
          if timeEmbeddingSize != cfgCond.shape[1] || !refiner.isConsistencyModel {
            cfgCond = graph.variable(like: t)
            cfgCond.full(0)
          }
          let (injectedControls, injectedT2IAdapters, injectedIPAdapters) =
            ControlModel<FloatType>
            .emptyInjectedControlsAndAdapters(
              injecteds: injectedControls, step: 0, version: refiner.version, inputs: xIn,
              tiledDiffusion: tiledDiffusion)
          let newC: [DynamicGraph.Tensor<FloatType>]
          if version == .svdI2v {
            newC = Array(c[0..<(1 + (c.count - 1) / 2)])
          } else {
            newC = c
          }
          let _ = unet.compileModel(
            filePath: refiner.filePath, externalOnDemand: refiner.externalOnDemand,
            version: refiner.version, upcastAttention: upcastAttention,
            usesFlashAttention: usesFlashAttention, injectControls: injectControls,
            injectT2IAdapters: injectT2IAdapters, injectIPAdapterLengths: injectIPAdapterLengths,
            lora: lora, is8BitModel: refiner.is8BitModel,
            canRunLoRASeparately: canRunLoRASeparately,
            inputs: xIn, t, newC,
            tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond,
            extraProjection: extraProjection, injectedControls: injectedControls,
            injectedT2IAdapters: injectedT2IAdapters, injectedIPAdapters: injectedIPAdapters,
            tiledDiffusion: tiledDiffusion)
          refinerKickIn = -1
          unets.append(unet)
        }
        let sigma = sigmas[timestep]
        let cNoise: Float
        switch conditioning {
        case .noise:
          cNoise = discretization.noise(for: alphasCumprod[timestep])
        case .timestep:
          cNoise = Float(timestep)
        }
        let t = unet.timeEmbed(
          graph: graph, batchSize: batchSize, timestep: cNoise, version: currentModelVersion)
        xIn[0..<batchSize, 0..<startHeight, 0..<startWidth, 0..<channels] = x
        let injectedIPAdapters = ControlModel<FloatType>
          .injectedIPAdapters(
            injecteds: injectedControls, step: i, version: unet.version,
            usesFlashAttention: usesFlashAttention, inputs: xIn, t, injectedControlsC,
            tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond,
            isCfgEnabled: false, mainUNetAndWeightMapper: unet.modelAndWeightMapper,
            controlNets: &controlNets)
        let injectedControlsAndAdapters = ControlModel<FloatType>
          .injectedControlsAndAdapters(
            injecteds: injectedControls, step: i, version: unet.version,
            usesFlashAttention: usesFlashAttention, inputs: xIn, t, injectedControlsC,
            tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond,
            isCfgEnabled: false, mainUNetAndWeightMapper: unet.modelAndWeightMapper,
            controlNets: &controlNets)
        let newC: [DynamicGraph.Tensor<FloatType>]
        if version == .svdI2v {
          newC = Array(c[0..<(1 + (c.count - 1) / 2)])
        } else {
          newC = c
        }
        var etOut = unet(
          timestep: cNoise, inputs: xIn, t + cfgCond, newC, extraProjection: extraProjection,
          injectedControlsAndAdapters: injectedControlsAndAdapters,
          injectedIPAdapters: injectedIPAdapters, tiledDiffusion: tiledDiffusion,
          controlNets: &controlNets)
        if let blur = blur {
          let alpha =
            0.001 * sharpness * (discretization.timesteps - Float(timestep))
            / discretization.timesteps
          let etOutDegraded = blur(inputs: etOut)[0].as(of: FloatType.self)
          etOut = Functional.add(
            left: etOutDegraded, right: etOut, leftScalar: alpha, rightScalar: 1 - alpha)
        }
        let alpha = alphasCumprod[timestep]
        let predictOriginalSample: DynamicGraph.Tensor<FloatType>
        switch discretization.objective {
        case .const:
          fatalError()
        case .v:
          let sqrtAlphaCumprod = 1.0 / (sigma * sigma + 1).squareRoot()
          predictOriginalSample = Functional.add(
            left: x, right: etOut, leftScalar: Float(sqrtAlphaCumprod),
            rightScalar: Float(-sigma * sqrtAlphaCumprod))
        case .epsilon:
          predictOriginalSample = Functional.add(
            left: x, right: etOut, leftScalar: Float(1.0 / alpha.squareRoot()),
            rightScalar: Float(-sigma))
        case .edm(let sigmaData):
          let sigmaData2 = sigmaData * sigmaData
          predictOriginalSample = Functional.add(
            left: x, right: etOut,
            leftScalar: Float(sigmaData2 / (sigma * sigma + sigmaData2).squareRoot()),
            rightScalar: Float(sigma * sigmaData / (sigma * sigma + sigmaData2).squareRoot()))
        }
        let (cSkip, cOut) = scalingsForBoundaryConditionDiscrete(timestep: timestep)
        let denoised = Functional.add(
          left: predictOriginalSample, right: x, leftScalar: cOut, rightScalar: cSkip)
        oldDenoised = denoised
        let alphaPrev = alphasCumprod[i + 1 < timesteps.count ? timesteps[i + 1] : 0]
        if i < sampling.steps - 1 {
          let noise = graph.variable(like: x)
          noise.randn(std: 1, mean: 0)
          x = Functional.add(
            left: denoised, right: noise, leftScalar: Float(alphaPrev.squareRoot()),
            rightScalar: Float((1 - alphaPrev).squareRoot()))
        } else {
          x = denoised
        }
        if i < endStep.integral - 1, let noise = noise, let sample = sample, let mask = mask,
          let negMask = negMask
        {
          noise.randn(std: 1, mean: 0)
          let qSample =
            Float(alphaPrev.squareRoot()) * sample + Float((1 - alphaPrev).squareRoot()) * noise
          x = qSample .* negMask + x .* mask
        }
        if i == endStep.integral - 1 {
          if isNaN(x.rawValue.toCPU()) {
            return .failure(SamplerError.isNaN)
          }
        }
      }
      return .success(SamplerOutput(x: x, unets: unets))
    }
    streamContext.joined()
    return result
  }

  public func timestep(for strength: Float, sampling: Sampling) -> (
    timestep: Float, startStep: Float, roundedDownStartStep: Int, roundedUpStartStep: Int
  ) {
    let tEnc = strength * discretization.timesteps
    let initTimestep = tEnc
    let alphasCumprod = discretization.alphasCumprod(steps: sampling.steps, shift: sampling.shift)
    var previousTimestep = discretization.timesteps
    for (i, alphaCumprod) in alphasCumprod.enumerated() {
      let timestep = discretization.timestep(for: alphaCumprod)
      if initTimestep >= timestep {
        guard i > 0 else {
          return (
            timestep: timestep, startStep: 0, roundedDownStartStep: 0, roundedUpStartStep: 0
          )
        }
        guard initTimestep > timestep + 1e-3 else {
          return (
            timestep: initTimestep, startStep: Float(i), roundedDownStartStep: i,
            roundedUpStartStep: i
          )
        }
        return (
          timestep: Float(initTimestep),
          startStep: Float(i - 1) + Float(initTimestep - previousTimestep)
            / Float(timestep - previousTimestep), roundedDownStartStep: i - 1, roundedUpStartStep: i
        )
      }
      previousTimestep = timestep
    }
    return (
      timestep: discretization.timestep(for: alphasCumprod[0]),
      startStep: Float(alphasCumprod.count - 1),
      roundedDownStartStep: alphasCumprod.count - 1, roundedUpStartStep: alphasCumprod.count - 1
    )
  }

  public func sampleScaleFactor(at step: Float, sampling: Sampling) -> Float {
    let step = Int(step.rounded())
    let alphasCumprod = discretization.alphasCumprod(steps: sampling.steps, shift: sampling.shift)
    let alphaCumprod = alphasCumprod[max(0, min(alphasCumprod.count - 1, step))]
    return Float(alphaCumprod.squareRoot())
  }

  public func noiseScaleFactor(at step: Float, sampling: Sampling) -> Float {
    let step = Int(step.rounded())
    let alphasCumprod = discretization.alphasCumprod(steps: sampling.steps, shift: sampling.shift)
    let alphaCumprod = alphasCumprod[max(0, min(alphasCumprod.count - 1, step))]
    return Float((1 - alphaCumprod).squareRoot())
  }
}
