import Foundation
import NNC

public struct EulerASampler<
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
  public let classifierFreeGuidance: Bool
  public let guidanceEmbed: Bool
  public let is8BitModel: Bool
  public let canRunLoRASeparately: Bool
  public let conditioning: Denoiser.Conditioning
  public let tiledDiffusion: TiledConfiguration
  private let discretization: Discretization
  public init(
    filePath: String, modifier: SamplerModifier, version: ModelVersion, usesFlashAttention: Bool,
    upcastAttention: Bool, externalOnDemand: Bool, injectControls: Bool,
    injectT2IAdapters: Bool, injectIPAdapterLengths: [Int], lora: [LoRAConfiguration],
    classifierFreeGuidance: Bool, guidanceEmbed: Bool, is8BitModel: Bool,
    canRunLoRASeparately: Bool,
    conditioning: Denoiser.Conditioning, tiledDiffusion: TiledConfiguration,
    discretization: Discretization
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
    self.classifierFreeGuidance = classifierFreeGuidance
    self.guidanceEmbed = guidanceEmbed
    self.is8BitModel = is8BitModel
    self.canRunLoRASeparately = canRunLoRASeparately
    self.conditioning = conditioning
    self.tiledDiffusion = tiledDiffusion
    self.discretization = discretization
  }
}

extension EulerASampler: Sampler {
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
    var c0 = c[0]
    let batchSize = x.shape[0]
    let startHeight = x.shape[1]
    let startWidth = x.shape[2]
    let channels = x.shape[3]
    let graph = x.graph
    var isCfgEnabled =
      classifierFreeGuidance
      && isCfgEnabled(
        textGuidanceScale: textGuidanceScale, startFrameCfg: startFrameCfg, version: version)
    let cfgChannels: Int
    let inChannels: Int
    if version == .svdI2v {
      cfgChannels = 1
      inChannels = channels * 2
    } else {
      switch modifier {
      case .inpainting:
        cfgChannels = isCfgEnabled ? 2 : 1
        inChannels = channels * 2 + 1
      case .depth:
        cfgChannels = isCfgEnabled ? 2 : 1
        inChannels = channels + 1
      case .editing:
        cfgChannels = 3
        inChannels = channels * 2
        isCfgEnabled = true
      case .none:
        cfgChannels = isCfgEnabled ? 2 : 1
        inChannels = channels
      }
    }
    let zeroNegativePrompt = isCfgEnabled && zeroNegativePrompt
    var xIn = graph.variable(
      .GPU(0), .NHWC(cfgChannels * batchSize, startHeight, startWidth, inChannels),
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
        if isCfgEnabled {
          xIn[
            (batchSize + i)..<(batchSize + i + 1), 0..<startHeight, 0..<startWidth,
            channels..<(channels + 1)] = mask
          xIn[
            (batchSize + i)..<(batchSize + i + 1), 0..<startHeight, 0..<startWidth,
            (channels + 1)..<(channels * 2 + 1)] =
            maskedImage
        }
      }
    case .editing:
      let maskedImage = maskedImage!
      for i in 0..<batchSize {
        xIn[i..<(i + 1), 0..<startHeight, 0..<startWidth, channels..<(channels * 2)] = maskedImage
        xIn[
          (batchSize + i)..<(batchSize + i + 1), 0..<startHeight, 0..<startWidth,
          channels..<(channels * 2)] =
          maskedImage
        xIn[
          (batchSize * 2 + i)..<(batchSize * 2 + i + 1), 0..<startHeight, 0..<startWidth,
          channels..<(channels * 2)
        ]
        .full(0)
      }
      let oldC = c0
      c0 = graph.variable(
        .GPU(0), .HWC(3 * batchSize, oldC.shape[1], oldC.shape[2]), of: FloatType.self)
      // Expanding c.
      c0[0..<(batchSize * 2), 0..<oldC.shape[1], 0..<oldC.shape[2]] = oldC
      c0[(batchSize * 2)..<(batchSize * 3), 0..<oldC.shape[1], 0..<oldC.shape[2]] =
        oldC[0..<batchSize, 0..<oldC.shape[1], 0..<oldC.shape[2]]
    case .depth:
      let depthImage = depthImage!
      for i in 0..<batchSize {
        xIn[i..<(i + 1), 0..<startHeight, 0..<startWidth, channels..<(channels + 1)] = depthImage
        if isCfgEnabled {
          xIn[
            (batchSize + i)..<(batchSize + i + 1), 0..<startHeight, 0..<startWidth,
            channels..<(channels + 1)] =
            depthImage
        }
      }
    case .none:
      break
    }
    var c = c
    var extraProjection = extraProjection
    var tokenLengthUncond = tokenLengthUncond
    if !isCfgEnabled && version != .svdI2v {
      for i in 0..<c.count {
        let shape = c[i].shape
        guard shape[0] >= batchSize * 2 else { continue }
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
        if shape[0] >= batchSize * 2 {
          if shape.count == 3 {
            // Only tokenLengthCond is used.
            projection = projection[batchSize..<(batchSize * 2), 0..<shape[1], 0..<shape[2]]
              .copied()
          } else if shape.count == 2 {
            projection = projection[batchSize..<(batchSize * 2), 0..<shape[1]].copied()
          }
        }
        extraProjection = projection
      }
      // There is no tokenLengthUncond any more.
      tokenLengthUncond = tokenLengthCond
    }
    let oldC = c
    let fixedEncoder = UNetFixedEncoder<FloatType>(
      filePath: filePath, version: version, usesFlashAttention: usesFlashAttention,
      zeroNegativePrompt: zeroNegativePrompt)
    let injectedControlsC: [[DynamicGraph.Tensor<FloatType>]]
    let alphasCumprod = discretization.alphasCumprod(steps: sampling.steps, shift: sampling.shift)
    let sigmas = alphasCumprod.map { discretization.sigma(from: $0) }
    let timesteps = (startStep.integral..<endStep.integral).map {
      let alphaCumprod: Double
      if $0 == startStep.integral && Float(startStep.integral) != startStep.fractional {
        let lowTimestep = discretization.timestep(
          for: alphasCumprod[max(0, min(Int(startStep.integral), alphasCumprod.count - 1))])
        let highTimestep = discretization.timestep(
          for: alphasCumprod[
            max(0, min(Int(startStep.fractional.rounded(.up)), alphasCumprod.count - 1))])
        let timestep =
          lowTimestep
          + Float(highTimestep - lowTimestep) * (startStep.fractional - Float(startStep.integral))
        alphaCumprod = discretization.alphaCumprod(timestep: timestep, shift: 1)
      } else {
        alphaCumprod = discretization.alphaCumprod(from: sigmas[$0])
      }
      switch conditioning {
      case .noise:
        return discretization.noise(for: alphaCumprod)
      case .timestep:
        return discretization.timestep(for: alphaCumprod)
      }
    }
    if UNetFixedEncoder<FloatType>.isFixedEncoderRequired(version: version) {
      let vector = fixedEncoder.vector(
        textEmbedding: c[c.count - 1], originalSize: originalSize,
        cropTopLeft: cropTopLeft,
        targetSize: targetSize, aestheticScore: aestheticScore,
        negativeOriginalSize: negativeOriginalSize, negativeAestheticScore: negativeAestheticScore,
        fpsId: fpsId, motionBucketId: motionBucketId, condAug: condAug)
      let (encodings, weightMapper) = fixedEncoder.encode(
        isCfgEnabled: isCfgEnabled, textGuidanceScale: textGuidanceScale,
        guidanceEmbed: guidanceEmbed,
        textEncoding: c, timesteps: timesteps, batchSize: batchSize, startHeight: startHeight,
        startWidth: startWidth,
        tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond, lora: lora,
        tiledDiffusion: tiledDiffusion)
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
    if existingUNets[0] == nil {
      let firstTimestep =
        discretization.timesteps - discretization.timesteps / Float(sampling.steps) + 1
      let t = unet.timeEmbed(
        graph: graph, batchSize: cfgChannels * batchSize, timestep: firstTimestep, version: version)
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
        inputs: xIn, t,
        unet.extractConditions(
          graph: graph, index: 0, batchSize: cfgChannels * batchSize, conditions: newC,
          version: version),
        tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond,
        extraProjection: extraProjection, injectedControls: injectedControls,
        injectedT2IAdapters: injectedT2IAdapters, injectedIPAdapters: injectedIPAdapters,
        tiledDiffusion: tiledDiffusion)
    }
    // Now do Euler ancesteral sampling.
    let noise = graph.variable(
      .GPU(0), .NHWC(batchSize, startHeight, startWidth, channels), of: FloatType.self)
    let condAugFrames: DynamicGraph.Tensor<FloatType>?
    let textGuidanceVector: DynamicGraph.Tensor<FloatType>?
    if version == .svdI2v {
      let scaleCPU = graph.variable(.CPU, .NHWC(batchSize, 1, 1, 1), of: FloatType.self)
      for i in 0..<batchSize {
        scaleCPU[i, 0, 0, 0] = FloatType(
          Float(i) * (textGuidanceScale - startFrameCfg) / Float(batchSize - 1) + startFrameCfg)
      }
      textGuidanceVector = scaleCPU.toGPU(0)
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
      condAugFrames = frames
    } else {
      textGuidanceVector = nil
      condAugFrames = nil
    }
    let blur: Model?
    if sharpness > 0 {
      blur = Blur(filters: channels, sigma: 3.0, size: 13, input: x)
    } else {
      blur = nil
    }
    let streamContext = StreamContext(.GPU(0))
    var refinerKickIn = refiner.map { (1 - $0.start) * discretization.timesteps } ?? -1
    var unets: [UNet?] = [unet]
    var currentModelVersion = version
    var indexOffset = startStep.integral
    let result: Result<SamplerOutput<FloatType, UNet>, Error> = graph.withStream(streamContext) {
      if startStep.fractional == 0 && sigmas[0] != 1 {  // Otherwise it is already scaled properly with the noiseScaleFactor and sampleScaleFactor.
        x = Float(sigmas[0]) * x
      }
      var oldDenoised: DynamicGraph.Tensor<FloatType>? = nil
      for i in startStep.integral..<endStep.integral {
        let sigma: Double
        if i == startStep.integral && Float(startStep.integral) != startStep.fractional {
          let lowTimestep = discretization.timestep(
            for: alphasCumprod[max(0, min(Int(startStep.integral), alphasCumprod.count - 1))])
          let highTimestep = discretization.timestep(
            for: alphasCumprod[
              max(0, min(Int(startStep.fractional.rounded(.up)), alphasCumprod.count - 1))])
          let timestep =
            lowTimestep
            + Float(highTimestep - lowTimestep) * (startStep.fractional - Float(startStep.integral))
          let alphaCumprod = discretization.alphaCumprod(timestep: timestep, shift: 1)
          sigma = discretization.sigma(from: alphaCumprod)
        } else {
          sigma = sigmas[i]
        }
        let alphaCumprod = discretization.alphaCumprod(from: sigma)
        let sqrtAlphaCumprod = alphaCumprod.squareRoot()
        let input: DynamicGraph.Tensor<FloatType>
        switch discretization.objective {
        case .u(_):
          input = x
        case .v, .epsilon:
          input = Float(sqrtAlphaCumprod) * x
        case .edm(let sigmaData):
          input = Float(1.0 / (sigma * sigma + sigmaData * sigmaData).squareRoot()) * x
        }
        let rawValue: Tensor<FloatType>? =
          (i > max(startStep.integral, sampling.steps / 2) || i % 2 == 1)
          ? oldDenoised?.rawValue.toCPU() : nil
        if i % 5 == 4, let rawValue = rawValue {
          if isNaN(rawValue) {
            return .failure(SamplerError.isNaN)
          }
        }
        guard feedback(i - startStep.integral, rawValue) else {
          return .failure(SamplerError.cancelled)
        }
        let timestep = discretization.timestep(for: alphaCumprod)
        if timestep < refinerKickIn, let refiner = refiner {
          let timesteps = (i..<endStep.integral).map {
            let alphaCumprod =
              $0 == i ? alphaCumprod : discretization.alphaCumprod(from: sigmas[$0])
            switch conditioning {
            case .noise:
              return discretization.noise(for: alphaCumprod)
            case .timestep:
              return discretization.timestep(for: alphaCumprod)
            }
          }
          unets = [nil]
          let fixedEncoder = UNetFixedEncoder<FloatType>(
            filePath: refiner.filePath, version: refiner.version,
            usesFlashAttention: usesFlashAttention, zeroNegativePrompt: zeroNegativePrompt)
          if UNetFixedEncoder<FloatType>.isFixedEncoderRequired(version: refiner.version) {
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
                isCfgEnabled: isCfgEnabled, textGuidanceScale: textGuidanceScale,
                guidanceEmbed: guidanceEmbed,
                textEncoding: oldC, timesteps: timesteps, batchSize: batchSize,
                startHeight: startHeight,
                startWidth: startWidth, tokenLengthUncond: tokenLengthUncond,
                tokenLengthCond: tokenLengthCond, lora: lora, tiledDiffusion: tiledDiffusion
              ).0
            indexOffset = i
          }
          unet = UNet()
          currentModelVersion = refiner.version
          let firstTimestep =
            discretization.timesteps - discretization.timesteps / Float(sampling.steps) + 1
          let t = unet.timeEmbed(
            graph: graph, batchSize: cfgChannels * batchSize, timestep: firstTimestep,
            version: currentModelVersion)
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
            inputs: xIn, t,
            unet.extractConditions(
              graph: graph, index: 0, batchSize: cfgChannels * batchSize, conditions: newC,
              version: currentModelVersion),
            tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond,
            extraProjection: extraProjection, injectedControls: injectedControls,
            injectedT2IAdapters: injectedT2IAdapters, injectedIPAdapters: injectedIPAdapters,
            tiledDiffusion: tiledDiffusion)
          refinerKickIn = -1
          unets.append(unet)
        }
        let cNoise: Float
        switch conditioning {
        case .noise:
          cNoise = discretization.noise(for: alphaCumprod)
        case .timestep:
          cNoise = timestep
        }
        let t = unet.timeEmbed(
          graph: graph, batchSize: cfgChannels * batchSize, timestep: cNoise,
          version: currentModelVersion)
        let c = unet.extractConditions(
          graph: graph, index: i - indexOffset, batchSize: cfgChannels * batchSize, conditions: c,
          version: currentModelVersion)
        let et: DynamicGraph.Tensor<FloatType>
        if version == .svdI2v, let textGuidanceVector = textGuidanceVector,
          let condAugFrames = condAugFrames
        {
          xIn[0..<batchSize, 0..<startHeight, 0..<startWidth, 0..<channels] = input
          xIn[0..<batchSize, 0..<startHeight, 0..<startWidth, channels..<(channels * 2)] =
            condAugFrames
          let injectedIPAdapters = ControlModel<FloatType>
            .injectedIPAdapters(
              injecteds: injectedControls, step: i, version: unet.version,
              usesFlashAttention: usesFlashAttention, inputs: xIn, t, injectedControlsC,
              tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond,
              isCfgEnabled: isCfgEnabled, mainUNetAndWeightMapper: unet.modelAndWeightMapper,
              controlNets: &controlNets)
          let injectedControlsAndAdapters = ControlModel<FloatType>
            .injectedControlsAndAdapters(
              injecteds: injectedControls, step: i, version: unet.version,
              usesFlashAttention: usesFlashAttention, inputs: xIn, t, injectedControlsC,
              tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond,
              isCfgEnabled: isCfgEnabled, mainUNetAndWeightMapper: unet.modelAndWeightMapper,
              controlNets: &controlNets)
          let cCond = Array(c[0..<(1 + (c.count - 1) / 2)])
          var etCond = unet(
            timestep: cNoise, inputs: xIn, t, cCond, extraProjection: extraProjection,
            injectedControlsAndAdapters: injectedControlsAndAdapters,
            injectedIPAdapters: injectedIPAdapters, tiledDiffusion: tiledDiffusion,
            controlNets: &controlNets)
          let alpha =
            0.001 * sharpness * (discretization.timesteps - timestep)
            / discretization.timesteps
          if isCfgEnabled {
            xIn[0..<batchSize, 0..<startHeight, 0..<startWidth, channels..<(channels * 2)].full(0)
            let cUncond = Array([c[0]] + c[(1 + (c.count - 1) / 2)...])
            let etUncond = unet(
              timestep: cNoise, inputs: xIn, t, cUncond, extraProjection: extraProjection,
              injectedControlsAndAdapters: injectedControlsAndAdapters,
              injectedIPAdapters: injectedIPAdapters, tiledDiffusion: tiledDiffusion,
              controlNets: &controlNets)
            if let blur = blur {
              let etCondDegraded = blur(inputs: etCond)[0].as(of: FloatType.self)
              etCond = Functional.add(
                left: etCondDegraded, right: etCond, leftScalar: alpha, rightScalar: 1 - alpha)
            }
            et = etUncond + textGuidanceVector .* (etCond - etUncond)
          } else {
            if let blur = blur {
              let etCondDegraded = blur(inputs: etCond)[0].as(of: FloatType.self)
              etCond = Functional.add(
                left: etCondDegraded, right: etCond, leftScalar: alpha, rightScalar: 1 - alpha)
            }
            et = etCond
          }
        } else {
          xIn[0..<batchSize, 0..<startHeight, 0..<startWidth, 0..<channels] = input
          if isCfgEnabled {
            xIn[batchSize..<(batchSize * 2), 0..<startHeight, 0..<startWidth, 0..<channels] = input
            if modifier == .editing {
              xIn[
                (batchSize * 2)..<(batchSize * 3), 0..<startHeight, 0..<startWidth, 0..<channels] =
                input
            }
          }
          let injectedIPAdapters = ControlModel<FloatType>
            .injectedIPAdapters(
              injecteds: injectedControls, step: i, version: unet.version,
              usesFlashAttention: usesFlashAttention, inputs: xIn, t, injectedControlsC,
              tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond,
              isCfgEnabled: isCfgEnabled, mainUNetAndWeightMapper: unet.modelAndWeightMapper,
              controlNets: &controlNets)
          let injectedControlsAndAdapters = ControlModel<FloatType>
            .injectedControlsAndAdapters(
              injecteds: injectedControls, step: i, version: unet.version,
              usesFlashAttention: usesFlashAttention, inputs: xIn, t, injectedControlsC,
              tokenLengthUncond: tokenLengthUncond, tokenLengthCond: tokenLengthCond,
              isCfgEnabled: isCfgEnabled, mainUNetAndWeightMapper: unet.modelAndWeightMapper,
              controlNets: &controlNets)
          var etOut = unet(
            timestep: cNoise, inputs: xIn, t, c, extraProjection: extraProjection,
            injectedControlsAndAdapters: injectedControlsAndAdapters,
            injectedIPAdapters: injectedIPAdapters, tiledDiffusion: tiledDiffusion,
            controlNets: &controlNets)
          let alpha =
            0.001 * sharpness * (discretization.timesteps - timestep)
            / discretization.timesteps
          if isCfgEnabled {
            var etUncond = graph.variable(
              .GPU(0), .NHWC(batchSize, startHeight, startWidth, channels), of: FloatType.self)
            var etCond = graph.variable(
              .GPU(0), .NHWC(batchSize, startHeight, startWidth, channels), of: FloatType.self)
            etUncond[0..<batchSize, 0..<startHeight, 0..<startWidth, 0..<channels] =
              etOut[0..<batchSize, 0..<startHeight, 0..<startWidth, 0..<channels]
            etCond[0..<batchSize, 0..<startHeight, 0..<startWidth, 0..<channels] =
              etOut[batchSize..<(batchSize * 2), 0..<startHeight, 0..<startWidth, 0..<channels]
            if let blur = blur {
              let etCondDegraded = blur(inputs: etCond)[0].as(of: FloatType.self)
              etCond = Functional.add(
                left: etCondDegraded, right: etCond, leftScalar: alpha, rightScalar: 1 - alpha)
            }
            if modifier == .editing {
              var etAllUncond = graph.variable(
                .GPU(0), .NHWC(batchSize, startHeight, startWidth, channels), of: FloatType.self)
              etAllUncond[0..<batchSize, 0..<startHeight, 0..<startWidth, 0..<channels] =
                etOut[
                  (batchSize * 2)..<(batchSize * 3), 0..<startHeight, 0..<startWidth, 0..<channels]
              et =
                etAllUncond + textGuidanceScale * (etCond - etUncond) + imageGuidanceScale
                * (etUncond - etAllUncond)
            } else {
              et = etUncond + textGuidanceScale * (etCond - etUncond)
            }
          } else {
            if channels < etOut.shape[3] {
              etOut = etOut[0..<batchSize, 0..<startHeight, 0..<startWidth, 0..<channels].copied()
            }
            if let blur = blur {
              let etOutDegraded = blur(inputs: etOut)[0].as(of: FloatType.self)
              etOut = Functional.add(
                left: etOutDegraded, right: etOut, leftScalar: alpha, rightScalar: 1 - alpha)
            }
            et = etOut
          }
        }
        let sigmaUp = min(
          sigmas[i + 1],
          1.0
            * ((sigmas[i + 1] * sigmas[i + 1]) * (sigma * sigma - sigmas[i + 1] * sigmas[i + 1])
            / (sigma * sigma)).squareRoot())
        let sigmaDown = (sigmas[i + 1] * sigmas[i + 1] - sigmaUp * sigmaUp).squareRoot()
        let dt = sigmaDown - sigma  // Notice this is already a negative.
        var denoised: DynamicGraph.Tensor<FloatType>
        switch discretization.objective {
        case .u(_):
          denoised = Functional.add(left: x, right: et, leftScalar: 1, rightScalar: Float(-sigma))
          x = Functional.add(
            left: x, right: et, leftScalar: Float(1 - sigmas[i + 1] + sigmaDown),
            rightScalar: Float(sigmaDown - sigma * sigmaDown - sigma * (1 - sigmas[i + 1])))
        case .v:
          // denoised = Float(1.0 / (sigma * sigma + 1)) * x - (sigma * sqrtAlphaCumprod) * et
          denoised = Functional.add(
            left: x, right: et, leftScalar: Float(1.0 / (sigma * sigma + 1)),
            rightScalar: Float(-sigma * sqrtAlphaCumprod))
          // d = (x - denoised) / sigma // (x - Float(1.0 / (sigma * sigma + 1)) * x + (sigma * sqrtAlphaCumprod) * et) / sigma = (sigma / (sigma * sigma + 1)) * x + sqrtAlphaCumprod * et
          let d = Functional.add(
            left: x, right: et, leftScalar: Float(sigma / (sigma * sigma + 1)),
            rightScalar: Float(sqrtAlphaCumprod))
          x = Functional.add(left: x, right: d, leftScalar: 1, rightScalar: Float(dt))
        case .epsilon:
          denoised = Functional.add(left: x, right: et, rightScalar: Float(-sigma))
          if version == .kandinsky21 {
            denoised = clipDenoised(denoised)
            let d = (x - denoised) * Float(1 / sigma)
            x = Functional.add(left: x, right: d, leftScalar: 1, rightScalar: Float(dt))
          } else {
            // denoised = x - sigma * et
            // d = (x - denoised) / sigma // (x - x + sigma * et) / sigma = et
            x = Functional.add(left: x, right: et, leftScalar: 1, rightScalar: Float(dt))
          }
        case .edm(let sigmaData):
          let sigmaData2 = sigmaData * sigmaData
          // denoised = Float(sigmaData2 / (sigma * sigma + sigmaData2)) * x + Float(sigma * sigmaData / (sigma * sigma + sigmaData2).squareRoot()) * et
          denoised = Functional.add(
            left: x, right: et, leftScalar: Float(sigmaData2 / (sigma * sigma + sigmaData2)),
            rightScalar: Float(sigma * sigmaData / (sigma * sigma + sigmaData2).squareRoot()))
          // d = (x - denoised) / sigma // (x - sigmaData2 / (sigma * sigma + sigmaData2) * x - (sigma * sigmaData / (sigma * sigma + sigmaData2).squareRoot()) * et) / sigma
          let d = Functional.add(
            left: x, right: et, leftScalar: Float(sigma / (sigma * sigma + sigmaData2)),
            rightScalar: Float(-sigmaData / (sigma * sigma + sigmaData2).squareRoot()))
          x = Functional.add(left: x, right: d, leftScalar: 1, rightScalar: Float(dt))
        }
        oldDenoised = denoised
        noise.randn(std: 1, mean: 0)
        if sigmaUp > 0 {
          x = Functional.add(left: x, right: noise, leftScalar: 1, rightScalar: Float(sigmaUp))
        }
        if i < endStep.integral - 1, let sample = sample, let mask = mask, let negMask = negMask {
          // If you check how we compute sigma, this is basically how we get back to alphaCumprod.
          // alphaPrev = 1 / (sigmas[i + 1] * sigmas[i + 1] + 1)
          // Then, we should compute qSample as alphaPrev.squareRoot() * sample + (1 - alphaPrev).squareRoot() * noise
          // However, because we will multiple back 1 / alphaPrev.squareRoot() again, this effectively become the following.
          let qSample: DynamicGraph.Tensor<FloatType>
          if case .u(_) = discretization.objective {
            qSample = Functional.add(
              left: sample, right: noise, leftScalar: Float(1 - sigmas[i + 1]),
              rightScalar: Float(sigmas[i + 1]))
          } else {
            qSample = sample + Float(sigmas[i + 1]) * noise
          }
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
    if case .u(_) = discretization.objective {
      return 1 - noiseScaleFactor(at: step, sampling: sampling)
    } else {
      return 1
    }
  }

  public func noiseScaleFactor(at step: Float, sampling: Sampling) -> Float {
    let alphasCumprod = discretization.alphasCumprod(steps: sampling.steps, shift: sampling.shift)
    let lowTimestep = discretization.timestep(
      for: alphasCumprod[max(0, min(Int(step.rounded(.down)), alphasCumprod.count - 1))])
    let highTimestep = discretization.timestep(
      for: alphasCumprod[max(0, min(Int(step.rounded(.up)), alphasCumprod.count - 1))])
    let timestep = lowTimestep + (highTimestep - lowTimestep) * (step - Float(step.rounded(.down)))
    let alphaCumprod = discretization.alphaCumprod(timestep: timestep, shift: 1)
    let sigma = discretization.sigma(from: alphaCumprod)
    return Float(sigma)
  }
}
