load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository", "new_git_repository")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_xcodeproj",
    sha256 = "bc8b1ae066b7333a151fd3a9ebee0d51d7779886bfb8cf9fc6e0f9d6c110fc83",
    url = "https://github.com/MobileNativeFoundation/rules_xcodeproj/releases/download/1.10.1/release.tar.gz",
)

load("@rules_xcodeproj//xcodeproj:repositories.bzl", "xcodeproj_rules_dependencies")

xcodeproj_rules_dependencies()

load("@bazel_features//:deps.bzl", "bazel_features_deps")

bazel_features_deps()

load("@build_bazel_rules_apple//apple:repositories.bzl", "apple_rules_dependencies")

apple_rules_dependencies()

load("@build_bazel_rules_swift//swift:repositories.bzl", "swift_rules_dependencies")

swift_rules_dependencies()

load("@build_bazel_rules_swift//swift:extras.bzl", "swift_rules_extra_dependencies")

swift_rules_extra_dependencies()

load("@build_bazel_apple_support//lib:repositories.bzl", "apple_support_dependencies")

apple_support_dependencies()

git_repository(
    name = "dflat",
    commit = "23ef1087cf768fc88193898c8cdd539c0b76449e",
    remote = "https://github.com/liuliu/dflat.git",
    shallow_since = "1686929921 -0700",
)

load("@dflat//:deps.bzl", "dflat_deps")

dflat_deps()

git_repository(
    name = "s4nnc",
    commit = "048d733d3d0c98983b80dc5f64516a69ff0bcd7b",
    remote = "https://github.com/liuliu/s4nnc.git",
    shallow_since = "1711132639 -0400",
)

load("@s4nnc//:deps.bzl", "s4nnc_deps")

s4nnc_deps()

load("@ccv//config:ccv.bzl", "ccv_deps", "ccv_setting")

ccv_deps()

load("@build_bazel_rules_cuda//gpus:cuda_configure.bzl", "cuda_configure")
load("@build_bazel_rules_cuda//nccl:nccl_configure.bzl", "nccl_configure")

cuda_configure(name = "local_config_cuda")

nccl_configure(name = "local_config_nccl")

ccv_setting(
    name = "local_config_ccv",
    have_accelerate_framework = True,
    have_pthread = True,
)

load("@s4nnc//:deps.bzl", "s4nnc_extra_deps")

s4nnc_extra_deps()

git_repository(
    name = "swift-fickling",
    commit = "296c8eb774332a3a49c8c403fdbec373d9fb2f96",
    remote = "https://github.com/liuliu/swift-fickling.git",
    shallow_since = "1675031846 -0500",
)

load("@swift-fickling//:deps.bzl", "swift_fickling_deps")

swift_fickling_deps()

git_repository(
    name = "swift-sentencepiece",
    commit = "2c4ec57bea836f8b420179ee7670304a4972c572",
    remote = "https://github.com/liuliu/swift-sentencepiece.git",
    shallow_since = "1683864360 -0400",
)

load("@swift-sentencepiece//:deps.bzl", "swift_sentencepiece_deps")

swift_sentencepiece_deps()

new_git_repository(
    name = "SwiftAlgorithms",
    remote = "https://github.com/apple/swift-algorithms.git",
    commit = "195e0316d7ba71e134d0f6c677f64b4db6160c46",
    shallow_since = "1645643239 -0600",
)

new_git_repository(
    name = "SwiftPNG",
    build_file = "swift-png.BUILD",
    commit = "075dfb248ae327822635370e9d4f94a5d3fe93b2",
    remote = "https://github.com/kelvin13/swift-png",
    shallow_since = "1645648674 -0600",
)

new_git_repository(
    name = "SwiftCollections",
    build_file = "swift-collections.BUILD",
    commit = "4196e652b101ccbbdb5431433b3a7ea0b414f708",
    remote = "https://github.com/apple/swift-collections.git",
    shallow_since = "1666233322 -0700",
)

new_git_repository(
    name = "SwiftArgumentParser",
    build_file = "swift-argument-parser.BUILD",
    commit = "82905286cc3f0fa8adc4674bf49437cab65a8373",
    remote = "https://github.com/apple/swift-argument-parser.git",
    shallow_since = "1647436700 -0500",
)

new_git_repository(
    name = "SwiftSystem",
    build_file = "swift-system.BUILD",
    commit = "836bc4557b74fe6d2660218d56e3ce96aff76574",
    remote = "https://github.com/apple/swift-system.git",
    shallow_since = "1638472952 -0800",
)

new_git_repository(
    name = "SwiftToolsSupportCore",
    build_file = "swift-tools-support-core.BUILD",
    commit = "b7667f3e266af621e5cc9c77e74cacd8e8c00cb4",
    remote = "https://github.com/apple/swift-tools-support-core.git",
    shallow_since = "1643831290 -0800",
)

new_git_repository(
    name = "SwiftSyntax",
    build_file = "swift-syntax.BUILD",
    commit = "cd793adf5680e138bf2bcbaacc292490175d0dcd",
    remote = "https://github.com/apple/swift-syntax.git",
    shallow_since = "1676877517 +0100",
)

new_git_repository(
    name = "SwiftFormat",
    build_file = "swift-format.BUILD",
    commit = "9f1cc7172f100118229644619ce9c8f9ebc1032c",
    remote = "https://github.com/apple/swift-format.git",
    shallow_since = "1676404655 +0000",
)

new_git_repository(
    name = "Highlightr",
    build_file = "swift-highlightr.BUILD",
    remote = "https://github.com/raspu/Highlightr",
    commit = "628094ff81cdebf31da6bf31be4b4ac758c127a4",
    shallow_since = "1672268165 +0100",
)

new_git_repository(
    name = "SwiftGuaka",
    build_file = "swift-guaka.BUILD",
    remote = "https://github.com/nsomar/Guaka",
    commit = "e52eb523b152e04fa5dff56bed01e805062ce0ff",
    shallow_since = "1570439330 +0900",
)

new_git_repository(
    name = "SwiftStringScanner",
    build_file = "swift-string-scanner.BUILD",
    remote = "https://github.com/getGuaka/StringScanner",
    commit = "de1685ad202cb586d626ed52d6de904dd34189f3",
    shallow_since = "1558131110 +0900",
)

new_git_repository(
    name = "cpp-httplib",
    build_file = "cpp-httplib.BUILD",
    commit = "bd9612b81e6f39ab24a4be52fcda93658c0ca2dc",
    remote = "https://github.com/yhirose/cpp-httplib",
    shallow_since = "1686982714 -0400",
)

# buildifier is written in Go and hence needs rules_go to be built.
# See https://github.com/bazelbuild/rules_go for the up to date setup instructions.

http_archive(
    name = "io_bazel_rules_go",
    sha256 = "099a9fb96a376ccbbb7d291ed4ecbdfd42f6bc822ab77ae6f1b5cb9e914e94fa",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/rules_go/releases/download/v0.35.0/rules_go-v0.35.0.zip",
        "https://github.com/bazelbuild/rules_go/releases/download/v0.35.0/rules_go-v0.35.0.zip",
    ],
)

load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")

go_rules_dependencies()

go_register_toolchains(version = "1.19.1")

http_archive(
    name = "bazel_gazelle",
    sha256 = "501deb3d5695ab658e82f6f6f549ba681ea3ca2a5fb7911154b5aa45596183fa",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/bazel-gazelle/releases/download/v0.26.0/bazel-gazelle-v0.26.0.tar.gz",
        "https://github.com/bazelbuild/bazel-gazelle/releases/download/v0.26.0/bazel-gazelle-v0.26.0.tar.gz",
    ],
)

load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies")

gazelle_dependencies()

git_repository(
    name = "com_github_bazelbuild_buildtools",
    commit = "174cbb4ba7d15a3ad029c2e4ee4f30ea4d76edce",
    remote = "https://github.com/bazelbuild/buildtools.git",
    shallow_since = "1607975103 +0100",
)

new_git_repository(
    name = "Yams",
    build_file = "yams.BUILD",
    commit = "948991e19e795cdd7bd310756a97b5fbda559535",
    remote = "https://github.com/jpsim/Yams.git",
    shallow_since = "1682361496 -0400",
)
