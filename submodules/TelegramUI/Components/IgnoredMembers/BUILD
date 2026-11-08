load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "IgnoredMembers",
    module_name = "IgnoredMembers",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/TelegramUIPreferences",
        "//submodules/AccountContext",
        "//submodules/ContextUI",
        "//submodules/ComponentFlow",
        "//submodules/ItemListUI",
        "//submodules/ItemListPeerItem",
        "//submodules/PresentationDataUtils",
    ],
    visibility = [
        "//visibility:public",
    ],
)
