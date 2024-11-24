import Foundation
import NNC

private let LoRALoaderShapeMismatchKeys: Set<String> = Set(["__dit__[t-x_embedder-0-0]"])

public struct LoRALoader<FloatType: TensorNumeric & BinaryFloatingPoint> {
  private static func _openStore(
    _ graph: DynamicGraph, lora: [LoRAConfiguration], index: Int,
    stores: [(file: String, DynamicGraph.Store)],
    handler: ([(file: String, DynamicGraph.Store)]) -> Void
  ) {
    guard index < lora.count else {
      handler(stores)
      return
    }
    graph.openStore(
      lora[index].file, flags: .readOnly,
      externalStore: TensorData.externalStore(filePath: lora[index].file)
    ) { store in
      _openStore(
        graph, lora: lora, index: index + 1, stores: stores + [(file: lora[index].file, store)],
        handler: handler)
    }
  }
  public static func openStore(
    _ graph: DynamicGraph, lora: [LoRAConfiguration], handler: (LoRALoader) -> Void
  ) {
    _openStore(graph, lora: lora, index: 0, stores: []) { stores in
      handler(LoRALoader(stores: stores, weights: lora.map(\.weight), isLoHas: lora.map(\.isLoHa)))
    }
  }
  // Compute the LoRA rank of all loras.
  public static func rank(
    _ graph: DynamicGraph, of files: [String], prefix: String = "",
    inspectFilesRequireMerge: Bool = true
  ) -> (
    rank: Int, filesRequireMerge: Set<String>
  ) {
    var filesRequireMerge = Set<String>()
    return (
      files.reduce(0) { oldRank, file in
        var rank: Int = 0
        graph.openStore(file, flags: .readOnly) {
          let keys = $0.keys
          for key in keys {
            guard prefix.isEmpty || key.hasPrefix(prefix) else { continue }
            // this is to check if it is a key for LoRA network directly.
            let isLoRADownNetworkKey = key.contains("-lora_down-")
            // If it doesn't have __ suffix but have a __ suffix (indicate it is a weight for model), then it is a "full" LoRA that requires a merge.
            guard isLoRADownNetworkKey || (key.hasSuffix("__") && key.hasPrefix("__")) else {
              if inspectFilesRequireMerge && key.hasPrefix("__") {
                filesRequireMerge.insert(file)
                break
              }
              continue
            }
            // This is to check if alternatively, this is the key for tensor patch.
            guard isLoRADownNetworkKey || key.hasSuffix("__down__") else { continue }
            guard let tensor = $0.read(like: key) else { continue }
            rank = max(rank, tensor.shape[0])
          }
        }
        return oldRank + rank
      }, filesRequireMerge
    )
  }
  public static func keys(_ graph: DynamicGraph, of files: [String], prefix: String = "")
    -> [String]
  {
    return Array(
      files.reduce(Set<String>()) { oldKeys, file in
        var keys = Set<String>()
        graph.openStore(file, flags: .readOnly) {
          for key in $0.keys {
            guard prefix.isEmpty || key.hasPrefix(prefix) else { continue }
            // this is to check if it is a key for LoRA network directly.
            let components = key.components(separatedBy: ["[", "]"])
            guard components.count >= 2, components[1].hasPrefix("t-") else { continue }
            keys.insert(String(components[1].dropFirst(2)))
          }
        }
        return oldKeys.union(keys)
      })
  }
  var stores: [(file: String, DynamicGraph.Store)]
  var weights: [Float]
  var isLoHas: [Bool]
  private let keys: [Set<String>]
  init(stores: [(file: String, DynamicGraph.Store)], weights: [Float], isLoHas: [Bool]) {
    self.stores = stores
    self.weights = weights
    self.isLoHas = isLoHas
    keys = stores.map(\.1).map { Set($0.keys) }
  }

  public func concatenateLoRA(
    _ graph: DynamicGraph, LoRAMapping: [Int: Int], filesRequireMerge: Set<String>, name: String,
    store: DynamicGraph.Store, dataType: DataType, format: TensorFormat, shape: TensorShape
  ) -> DynamicGraph.Store.ModelReaderResult {
    guard name.contains("lora_up") || name.contains("lora_down") else {
      return mergeLoRA(
        graph, name: name, store: store, shape: shape, filesRequireMerge: filesRequireMerge)
    }
    // If it is these, we have to create the LoRA tensor one way or another. First create, then loop through to fill them.
    precondition(dataType == FloatType.dataType)
    var tensor = Tensor<FloatType>(.CPU, .NC(shape[0], shape[1...].reduce(1, *)))
    tensor.withUnsafeMutableBytes {
      let size = shape.reduce(MemoryLayout<FloatType>.size, *)
      memset($0.baseAddress!, 0, size)
    }
    let components = name.split(separator: "-")
    guard components.count >= 3, let index = Int(components[2]),
      let originalIndex = LoRAMapping[index]
    else { return .final(tensor) }
    var infix = components[1].replacingOccurrences(of: "lora_up", with: "").replacingOccurrences(
      of: "lora_down", with: "")
    // In case infix has _, remove them.
    if infix.hasSuffix("_") {
      infix = String(infix.prefix(upTo: infix.index(before: infix.endIndex)))
    }
    let originalPrefix: String
    if infix.isEmpty {
      originalPrefix = "\(components[0])-\(originalIndex)-0]"
    } else {
      originalPrefix = "\(components[0])-\(infix)-\(originalIndex)-0]"
    }
    let isUp = name.contains("lora_up")
    var rank = 0
    let tensorShape = tensor.shape
    for (store, weight) in zip(stores, weights) {
      guard !filesRequireMerge.contains(store.file) else { continue }
      let store = store.1
      guard
        let loadedTensor = store.read(
          originalPrefix + (isUp ? "__up__" : "__down__"),
          codec: [.q6p, .q8p, .ezm7, .externalData])
      else { continue }
      let formattedTensor = Tensor<FloatType>(from: loadedTensor).reshaped(
        .NC(loadedTensor.shape[0], loadedTensor.shape[1...].reduce(1, *)))
      let newRank = isUp ? formattedTensor.shape[1] : formattedTensor.shape[0]
      let oldRank = rank
      rank += newRank
      if weight == 1 {
        if isUp {
          tensor[0..<tensorShape[0], oldRank..<(oldRank + newRank)] =
            formattedTensor[0..<tensorShape[0], 0..<newRank].toCPU()
        } else {
          guard
            let loraMid = store.read(
              originalPrefix + "__mid__", codec: [.q6p, .q8p, .ezm7, .externalData])
          else {
            let shape1 = min(tensorShape[1], formattedTensor.shape[1])
            tensor[oldRank..<(oldRank + newRank), 0..<shape1] =
              formattedTensor[0..<newRank, 0..<shape1].toCPU()
            continue
          }
          let down = graph.variable(
            formattedTensor[0..<newRank, 0..<formattedTensor.shape[1]].toGPU(0))
          let loraMidTensor = Tensor<FloatType>(from: loraMid)
          let mid = graph.variable(loraMidTensor.toGPU(0))
          var midDown = mid.transposed(0, 1)
          midDown = midDown.reshaped(.NC(midDown.shape[0], midDown.shape[1...].reduce(1, *)))
          midDown = Functional.matmul(left: down, right: midDown, leftTranspose: (0, 1))
          midDown = midDown.reshaped(
            .NCHW(midDown.shape[0], mid.shape[0], mid.shape[2], mid.shape[3])
          ).transposed(0, 1)
          midDown = midDown.reshaped(.NC(midDown.shape[0], midDown.shape[1...].reduce(1, *)))
          let shape1 = min(tensorShape[1], midDown.shape[1])
          tensor[oldRank..<(oldRank + newRank), 0..<shape1] = midDown[
            0..<newRank, 0..<shape1
          ].rawValue.toCPU()
        }
      } else {
        let sqrtWeightDown = weight >= 0 ? weight.squareRoot() : (-weight).squareRoot()
        let sqrtWeightUp = weight >= 0 ? sqrtWeightDown : -sqrtWeightDown
        if isUp {
          tensor[0..<tensorShape[0], oldRank..<(oldRank + newRank)] =
            (sqrtWeightUp
            * graph.variable(formattedTensor[0..<tensorShape[0], 0..<newRank].toGPU(0)))
            .rawValue.toCPU()
        } else {
          guard
            let loraMid = store.read(
              originalPrefix + "__mid__", codec: [.q6p, .q8p, .ezm7, .externalData])
          else {
            let shape1 = min(tensorShape[1], formattedTensor.shape[1])
            tensor[oldRank..<(oldRank + newRank), 0..<shape1] =
              (sqrtWeightDown
              * graph.variable(formattedTensor[0..<newRank, 0..<shape1].toGPU(0)))
              .rawValue.toCPU()
            continue
          }
          let down = graph.variable(
            formattedTensor[0..<newRank, 0..<formattedTensor.shape[1]].toGPU(0))
          let loraMidTensor = Tensor<FloatType>(from: loraMid)
          let mid = graph.variable(loraMidTensor.toGPU(0))
          var midDown = mid.transposed(0, 1)
          midDown = midDown.reshaped(.NC(midDown.shape[0], midDown.shape[1...].reduce(1, *)))
          midDown = Functional.matmul(left: down, right: midDown, leftTranspose: (0, 1))
          midDown = midDown.reshaped(
            .NCHW(midDown.shape[0], mid.shape[0], mid.shape[2], mid.shape[3])
          ).transposed(0, 1)
          midDown = midDown.reshaped(.NC(midDown.shape[0], midDown.shape[1...].reduce(1, *)))
          let shape1 = min(tensorShape[1], midDown.shape[1])
          tensor[oldRank..<(oldRank + newRank), 0..<shape1] =
            (sqrtWeightDown * midDown[0..<newRank, 0..<shape1]).rawValue.toCPU()
        }
      }
    }
    return .final(tensor)
  }

  private func loadOriginal(
    _ graph: DynamicGraph, name: String, store: DynamicGraph.Store, shape: TensorShape
  ) -> DynamicGraph.Tensor<FloatType>? {
    // Load tensor into a particular shape, shape it and fill with 0s if needed.
    // Only use this method for shape that has 4-element.
    guard
      let original =
        (store.read(name, codec: [.q6p, .q8p, .ezm7, .externalData]).map {
          graph.variable(Tensor<FloatType>(from: $0).toGPU(0))
        })
    else { return nil }
    let originalShape = original.shape
    let shape123 = shape[1...].reduce(1, *)
    guard originalShape[1] != shape[1] && originalShape.reduce(1, *) != shape[0] * shape123 else {
      return original
    }
    assert(originalShape[0] == shape[0])
    let shape1 = originalShape.count > 2 ? shape123 / originalShape[2...].reduce(1, *) : shape123
    if originalShape.count == 4 {
      var blank = graph.variable(
        .GPU(0), .NCHW(originalShape[0], shape1, originalShape[2], originalShape[3]),
        of: FloatType.self)
      if shape[1] > originalShape[1] {
        blank.full(0)
        blank[
          0..<originalShape[0], 0..<originalShape[1], 0..<originalShape[2], 0..<originalShape[3]] =
          original
      } else {
        blank[0..<originalShape[0], 0..<shape1, 0..<originalShape[2], 0..<originalShape[3]] =
          original[0..<originalShape[0], 0..<shape1, 0..<originalShape[2], 0..<originalShape[3]]
      }
      return blank
    } else {
      var blank = graph.variable(.GPU(0), .NC(originalShape[0], shape1), of: FloatType.self)
      if shape1 > originalShape[1] {
        blank.full(0)
        blank[0..<originalShape[0], 0..<originalShape[1]] = original
      } else {
        blank[0..<originalShape[0], 0..<shape1] = original[0..<originalShape[0], 0..<shape1]
      }
      return blank
    }
  }

  private func addWeight(
    original: DynamicGraph.Tensor<FloatType>, diff: DynamicGraph.Tensor<FloatType>, weight: Float
  ) -> DynamicGraph.Tensor<FloatType> {
    // Only use this method for shape that has 4-element.
    let diffCount = diff.shape.reduce(1, *)
    let originalShape = original.shape
    guard originalShape.reduce(1, *) != diffCount else {
      return Functional.add(
        left: original, right: diff.reshaped(format: .NCHW, shape: originalShape),
        leftScalar: 1, rightScalar: weight)
    }
    precondition(originalShape.count == 4)
    // If they are of different shape, we try to guess the second dim assuming on original it has 4-element.
    guard (diffCount % (originalShape[0] * originalShape[2] * originalShape[3])) == 0 else {
      assertionFailure()
      return Functional.add(
        left: original, right: diff.reshaped(format: .NCHW, shape: originalShape),
        leftScalar: 1, rightScalar: weight)
    }
    let diffShape1 = diffCount / (originalShape[0] * originalShape[2] * originalShape[3])
    if diffShape1 > originalShape[1] {
      return Functional.add(
        left: original,
        right: diff.reshaped(
          format: .NCHW, shape: originalShape,
          strides: [
            diffShape1 * originalShape[2] * originalShape[3], originalShape[2] * originalShape[3],
            originalShape[3], 1,
          ]),
        leftScalar: 1, rightScalar: weight)
    } else {
      precondition(diffShape1 < originalShape[1])
      var original = original
      original[0..<originalShape[0], 0..<diffShape1, 0..<originalShape[2], 0..<originalShape[3]] =
        Functional.add(
          left: original[
            0..<originalShape[0], 0..<diffShape1, 0..<originalShape[2], 0..<originalShape[3]],
          right: diff.reshaped(
            .NCHW(originalShape[0], diffShape1, originalShape[2], originalShape[3])), leftScalar: 1,
          rightScalar: weight)
      return original
    }
  }

  private func shapeMismatch(
    _ graph: DynamicGraph, name: String, store: DynamicGraph.Store, shape: TensorShape
  ) -> DynamicGraph.Store.ModelReaderResult {
    guard LoRALoaderShapeMismatchKeys.contains(name) else { return .continue(name) }
    // Check the shape.
    guard let originalShape = store.read(like: name)?.shape else { return .continue(name) }
    // Check if the shape match or not, in case it doesn't match, we need to return.
    guard originalShape[1] != shape[1] && originalShape.reduce(1, *) != shape.reduce(1, *) else {
      return .continue(name)
    }
    guard
      let original =
        (store.read(name, codec: [.q6p, .q8p, .ezm7, .externalData]).map {
          Tensor<FloatType>(from: $0)
        })
    else {
      return .continue(name)
    }
    let originalShape1 = originalShape[1...].reduce(1, *)
    let shape1 = shape[1...].reduce(1, *)
    var tensor = Tensor<FloatType>(.CPU, .NC(shape[0], shape1))
    tensor.withUnsafeMutableBytes {
      let size = shape.reduce(MemoryLayout<FloatType>.size, *)
      memset($0.baseAddress!, 0, size)
    }
    let otherShape1 = min(shape1, originalShape1)
    tensor[0..<shape[0], 0..<otherShape1] = original[0..<shape[0], 0..<otherShape1]
    return .final(tensor)
  }

  public func mergeLoRA(
    _ graph: DynamicGraph, name: String, store: DynamicGraph.Store, shape: TensorShape,
    prefix: String = "", filesRequireMerge: Set<String>? = nil
  )
    -> DynamicGraph.Store.ModelReaderResult
  {
    // If filesRequireMerge is provided and it is not empty, we need to merge, otherwise we don't need to merge anything.
    guard !(filesRequireMerge?.isEmpty ?? false) else {
      return shapeMismatch(graph, name: name, store: store, shape: shape)
    }
    guard
      keys.contains(where: {
        $0.contains(prefix + name + "__up__") && $0.contains(prefix + name + "__down__")
          || ($0.contains(prefix + name + "__w1_a__") && $0.contains(prefix + name + "__w1_b__")
            && $0.contains(prefix + name + "__w2_a__") && $0.contains(prefix + name + "__w2_b__"))
          || $0.contains(prefix + name)
      })
    else {
      return shapeMismatch(graph, name: name, store: store, shape: shape)
    }
    // No need to read the original yet. This helps in case we don't have LoRA, we can still load original 8-bit weights.
    var original: DynamicGraph.Tensor<FloatType>? = nil
    let mainStore = store
    if shape.count == 4 {
      for (store, (weight, isLoHa)) in zip(stores, zip(weights, isLoHas)) {
        guard filesRequireMerge?.contains(store.file) ?? true else { continue }
        let store = store.1
        if isLoHa {
          guard
            let loHaW1A = store.read(
              prefix + name + "__w1_a__", codec: [.q6p, .q8p, .ezm7, .externalData]),
            let loHaW1B = store.read(
              prefix + name + "__w1_b__", codec: [.q6p, .q8p, .ezm7, .externalData]),
            let loHaW2A = store.read(
              prefix + name + "__w2_a__", codec: [.q6p, .q8p, .ezm7, .externalData]),
            let loHaW2B = store.read(
              prefix + name + "__w2_b__", codec: [.q6p, .q8p, .ezm7, .externalData])
          else { continue }
          let w1ATensor = Tensor<FloatType>(from: loHaW1A)
          let w1A = graph.variable(
            w1ATensor.reshaped(
              .NC(
                w1ATensor.shape[0],
                w1ATensor.shape[1...].reduce(1, *))
            ).toGPU(0))
          let w1BTensor = Tensor<FloatType>(from: loHaW1B)
          let w1B = graph.variable(
            w1BTensor.reshaped(
              .NC(
                w1BTensor.shape[0],
                w1BTensor.shape[1...].reduce(1, *))
            ).toGPU(0))
          let w2ATensor = Tensor<FloatType>(from: loHaW2A)
          let w2A = graph.variable(
            w2ATensor.reshaped(
              .NC(
                w2ATensor.shape[0],
                w2ATensor.shape[1...].reduce(1, *))
            ).toGPU(0))
          let w2BTensor = Tensor<FloatType>(from: loHaW2B)
          let w2B = graph.variable(
            w2BTensor.reshaped(
              .NC(
                w2BTensor.shape[0],
                w2BTensor.shape[1...].reduce(1, *))
            ).toGPU(0))
          if original == nil {
            original = loadOriginal(graph, name: name, store: mainStore, shape: shape)
          }
          original = original.map {
            addWeight(original: $0, diff: (w1A * w1B) .* (w2A * w2B), weight: weight)
          }
        } else {
          guard
            let loraUp = store.read(
              prefix + name + "__up__", codec: [.q6p, .q8p, .ezm7, .externalData]),
            let loraDown = store.read(
              prefix + name + "__down__", codec: [.q6p, .q8p, .ezm7, .externalData])
          else {
            guard let diff = store.read(prefix + name, codec: [.q6p, .q8p, .ezm7, .externalData])
            else { continue }
            if original == nil {
              original = loadOriginal(graph, name: name, store: mainStore, shape: shape)
            }
            original = original.map {
              let diff = graph.variable(Tensor<FloatType>(from: diff).toGPU(0))
              return addWeight(original: $0, diff: diff, weight: weight)
            }
            continue
          }
          let loraUpTensor = Tensor<FloatType>(from: loraUp)
          let up = graph.variable(
            loraUpTensor.reshaped(
              .NC(
                loraUpTensor.shape[0],
                loraUpTensor.shape[1...].reduce(1, *))
            ).toGPU(0))
          let loraDownTensor = Tensor<FloatType>(from: loraDown)
          let down = graph.variable(
            loraDownTensor.reshaped(
              .NC(
                loraDownTensor.shape[0],
                loraDownTensor.shape[1...].reduce(1, *))
            ).toGPU(0))
          guard
            let loraMid = store.read(
              prefix + name + "__mid__", codec: [.q6p, .q8p, .ezm7, .externalData])
          else {
            if original == nil {
              original = loadOriginal(graph, name: name, store: mainStore, shape: shape)
            }
            original = original.map {
              addWeight(original: $0, diff: up * down, weight: weight)
            }
            continue
          }
          let loraMidTensor = Tensor<FloatType>(from: loraMid)
          let mid = graph.variable(loraMidTensor.toGPU(0))
          var midDown = mid.transposed(0, 1)
          midDown = midDown.reshaped(.NC(midDown.shape[0], midDown.shape[1...].reduce(1, *)))
          midDown = Functional.matmul(left: down, right: midDown, leftTranspose: (0, 1))
          midDown = midDown.reshaped(
            .NCHW(midDown.shape[0], mid.shape[0], mid.shape[2], mid.shape[3])
          ).transposed(0, 1)
          midDown = midDown.reshaped(.NC(midDown.shape[0], midDown.shape[1...].reduce(1, *)))
          if original == nil {
            original = loadOriginal(graph, name: name, store: mainStore, shape: shape)
          }
          original = original.map {
            addWeight(original: $0, diff: up * midDown, weight: weight)
          }
        }
      }
    } else {
      for (store, (weight, isLoHa)) in zip(stores, zip(weights, isLoHas)) {
        guard filesRequireMerge?.contains(store.file) ?? true else { continue }
        let store = store.1
        if isLoHa {
          guard
            let loHaW1A = store.read(
              prefix + name + "__w1_a__", codec: [.q6p, .q8p, .ezm7, .externalData]),
            let loHaW1B = store.read(
              prefix + name + "__w1_b__", codec: [.q6p, .q8p, .ezm7, .externalData]),
            let loHaW2A = store.read(
              prefix + name + "__w2_a__", codec: [.q6p, .q8p, .ezm7, .externalData]),
            let loHaW2B = store.read(
              prefix + name + "__w2_b__", codec: [.q6p, .q8p, .ezm7, .externalData])
          else { continue }
          let w1A = graph.variable(Tensor<FloatType>(from: loHaW1A).toGPU(0))
          let w1B = graph.variable(Tensor<FloatType>(from: loHaW1B).toGPU(0))
          let w2A = graph.variable(Tensor<FloatType>(from: loHaW2A).toGPU(0))
          let w2B = graph.variable(Tensor<FloatType>(from: loHaW2B).toGPU(0))
          if original == nil {
            original = mainStore.read(name, codec: [.q6p, .q8p, .ezm7, .externalData]).map {
              graph.variable(Tensor<FloatType>(from: $0).toGPU(0))
            }
          }
          original = original.map {
            Functional.add(
              left: $0, right: (w1A * w1B) .* (w2A * w2B), leftScalar: 1, rightScalar: weight)
          }
        } else {
          guard
            let loraUp = store.read(
              prefix + name + "__up__", codec: [.q6p, .q8p, .ezm7, .externalData]),
            let loraDown = store.read(
              prefix + name + "__down__", codec: [.q6p, .q8p, .ezm7, .externalData])
          else {
            guard let diff = store.read(prefix + name, codec: [.q6p, .q8p, .ezm7, .externalData])
            else { continue }
            if original == nil {
              original = mainStore.read(name, codec: [.q6p, .q8p, .ezm7, .externalData]).map {
                graph.variable(Tensor<FloatType>(from: $0).toGPU(0))
              }
            }
            original = original.map {
              let diff = graph.variable(Tensor<FloatType>(from: diff).toGPU(0))
              return Functional.add(
                left: $0, right: diff, leftScalar: 1, rightScalar: weight)
            }
            continue
          }
          let up = graph.variable(Tensor<FloatType>(from: loraUp).toGPU(0))
          let down = graph.variable(Tensor<FloatType>(from: loraDown).toGPU(0))
          guard
            let loraMid = store.read(
              prefix + name + "__mid__", codec: [.q6p, .q8p, .ezm7, .externalData])
          else {
            if original == nil {
              original = mainStore.read(name, codec: [.q6p, .q8p, .ezm7, .externalData]).map {
                graph.variable(Tensor<FloatType>(from: $0).toGPU(0))
              }
            }
            original = original.map {
              Functional.add(
                left: $0, right: up * down, leftScalar: 1, rightScalar: weight)
            }
            continue
          }
          let loraMidTensor = Tensor<FloatType>(from: loraMid)
          let mid = graph.variable(loraMidTensor.toGPU(0))
          var midDown = mid.transposed(0, 1)
          midDown = midDown.reshaped(.NC(midDown.shape[0], midDown.shape[1...].reduce(1, *)))
          midDown = Functional.matmul(left: down, right: midDown, leftTranspose: (0, 1))
          midDown = midDown.reshaped(
            .NCHW(midDown.shape[0], mid.shape[0], mid.shape[2], mid.shape[3])
          ).transposed(0, 1)
          midDown = midDown.reshaped(.NC(midDown.shape[0], midDown.shape[1...].reduce(1, *)))
          if original == nil {
            original = mainStore.read(name, codec: [.q6p, .q8p, .ezm7, .externalData]).map {
              graph.variable(Tensor<FloatType>(from: $0).toGPU(0))
            }
          }
          original = original.map {
            Functional.add(
              left: $0, right: (up * midDown).reshaped(format: .NCHW, shape: $0.shape),
              leftScalar: 1, rightScalar: weight)
          }
        }
      }
    }
    guard let original = original else { return .continue(name) }
    return .final(original.rawValue.toCPU())
  }
}
