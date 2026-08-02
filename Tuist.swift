import ProjectDescription

let tuist = Tuist(
  fullHandle: "supabitapp/supacode",
  project: .tuist(
    // Development targets macOS 15, whose toolchains start at Xcode 16. The
    // ghostty Zig build keeps its own stricter Xcode 26.3 check in
    // scripts/select-developer-dir.sh, so only relax the generation gate here.
    compatibleXcodeVersions: .upToNextMajor("16.0"),
    swiftVersion: "6.0",
    generationOptions: .options(
      optionalAuthentication: true
    ),
    cacheOptions: .options(
      profiles: .profiles(
        [
          "development": .profile(
            .allPossible,
            except: [
              .named("GhosttyKit"),
            ]
          ),
        ],
        default: .custom("development")
      )
    )
  )
)
