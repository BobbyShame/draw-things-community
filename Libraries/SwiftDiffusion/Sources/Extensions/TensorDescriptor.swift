import Fickling
import Foundation
import NNC
import ZIPFoundation

public enum InflateError: Error {
  case tensorNotFound
  case dataNoBaseAddress
  case interrupted
}

public struct Storage {
  var name: String
  var size: Int
  var dataType: DataType
  var BF16: Bool
}

public struct TensorDescriptor {
  public var storage: Storage
  public var storageOffset: Int
  public var shape: [Int]
  public var strides: [Int]
}

extension TensorDescriptor {
  public func inflate<T: TensorNumeric>(from archive: TensorArchive, of type: T.Type) throws
    -> Tensor<T>
  {
    return try archive.with(self) {
      Tensor<T>(from: $0).copied()
    }
  }
}

extension ModelWeightElement {
  public func write<FloatType: BinaryFloatingPoint & TensorNumeric>(
    to store: DynamicGraph.Store, tensor: Tensor<FloatType>, format: Format, isDiagonal: Bool,
    renamer: (String) -> String
  ) {
    let shape = tensor.shape
    switch format {
    case .O:
      if self.count > 1 && self.format == .O {
        let count = shape[0] / self.count
        if isDiagonal {
          let jCount = shape[1] / self.count
          for (i, name) in self.enumerated() {
            store.write(
              renamer(name),
              tensor: tensor[
                (i * count)..<((i + 1) * count), (i * jCount)..<((i + 1) * jCount)
              ].copied())
          }
        } else {
          if let offsets = offsets {
            for (i, name) in self.enumerated() {
              store.write(
                renamer(name),
                tensor: tensor[
                  (offsets[i])..<(i < offsets.count - 1 ? offsets[i + 1] : shape[0]),
                  0..<tensor.shape[1]
                ]
                .copied())
            }
          } else {
            for (i, name) in self.enumerated() {
              store.write(
                renamer(name),
                tensor: tensor[(i * count)..<((i + 1) * count), 0..<tensor.shape[1]]
                  .copied())
            }
          }
        }
      } else {
        for name in self {
          store.write(renamer(name), tensor: tensor)
        }
      }
    case .I:
      if self.count > 1 && (self.format == .I || isDiagonal) {
        let shape = tensor.shape
        if self.format == .I {
          if let offsets = offsets {
            for (i, name) in self.enumerated() {
              store.write(
                renamer(name),
                tensor: tensor[
                  0..<shape[0],
                  offsets[i]..<(i < offsets.count - 1 ? offsets[i + 1] : shape[1])
                ].copied())
            }
          } else {
            let count = shape[1] / self.count
            for (i, name) in self.enumerated() {
              store.write(
                renamer(name),
                tensor: tensor[0..<shape[0], (i * count)..<((i + 1) * count)].copied())
            }
          }
        } else {
          let count = shape[0] / self.count
          if shape.count == 2 {
            for (i, name) in self.enumerated() {
              store.write(
                renamer(name),
                tensor: tensor[(i * count)..<((i + 1) * count), 0..<shape[1]].copied())
            }
          } else if shape.count == 4 {
            for (i, name) in self.enumerated() {
              store.write(
                renamer(name),
                tensor: tensor[
                  (i * count)..<((i + 1) * count), 0..<shape[1], 0..<shape[2],
                  0..<shape[3]
                ].copied())
            }
          }
        }
      } else {
        for name in self {
          store.write(renamer(name), tensor: tensor)
        }
      }
    }
  }
}
