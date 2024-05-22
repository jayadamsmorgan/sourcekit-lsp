//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import BuildServerProtocol
import LSPLogging
import LanguageServerProtocol

import struct TSCBasic.AbsolutePath

/// Defines how well a `BuildSystem` can handle a file with a given URI.
public enum FileHandlingCapability: Comparable, Sendable {
  /// The build system can't handle the file at all
  case unhandled

  /// The build system has fallback build settings for the file
  case fallback

  /// The build system knows how to handle the file
  case handled
}

public struct SourceFileInfo: Sendable {
  /// The URI of the source file.
  public let uri: DocumentURI

  /// `true` if this file belongs to the root project that the user is working on. It is false, if the file belongs
  /// to a dependency of the project.
  public let isPartOfRootProject: Bool

  /// Whether the file might contain test cases. This property is an over-approximation. It might be true for files
  /// from non-test targets or files that don't actually contain any tests. Keeping this list of files with
  /// `mayContainTets` minimal as possible helps reduce the amount of work that the syntactic test indexer needs to
  /// perform.
  public let mayContainTests: Bool

  public init(uri: DocumentURI, isPartOfRootProject: Bool, mayContainTests: Bool) {
    self.uri = uri
    self.isPartOfRootProject = isPartOfRootProject
    self.mayContainTests = mayContainTests
  }
}

/// A target / run destination combination. For example, a configured target can represent building the target
/// `MyLibrary` for iOS.
public struct ConfiguredTarget: Hashable, Sendable, CustomLogStringConvertible {
  /// An opaque string that represents the target.
  ///
  /// The target's ID should be generated by the build system that handles the target and only interpreted by that
  /// build system.
  public let targetID: String

  /// An opaque string that represents the run destination.
  ///
  /// The run destination's ID should be generated by the build system that handles the target and only interpreted by
  /// that build system.
  public let runDestinationID: String

  public init(targetID: String, runDestinationID: String) {
    self.targetID = targetID
    self.runDestinationID = runDestinationID
  }

  public var description: String {
    "\(targetID)-\(runDestinationID)"
  }

  public var redactedDescription: String {
    "\(targetID.hashForLogging)-\(runDestinationID.hashForLogging)"
  }
}

/// An error build systems can throw from `prepare` if they don't support preparation of targets.
public struct PrepareNotSupportedError: Error, CustomStringConvertible {
  public init() {}

  public var description: String { "Preparation not supported" }
}

/// Provider of FileBuildSettings and other build-related information.
///
/// The primary role of the build system is to answer queries for
/// FileBuildSettings and to notify its delegate when they change. The
/// BuildSystem is also the source of related information, such as where the
/// index datastore is located.
///
/// For example, a SwiftPMWorkspace provides compiler arguments for the files
/// contained in a SwiftPM package root directory.
public protocol BuildSystem: AnyObject, Sendable {
  /// The root of the project that this build system manages. For example, for SwiftPM packages, this is the folder
  /// containing Package.swift. For compilation databases it is the root folder based on which the compilation database
  /// was found.
  var projectRoot: AbsolutePath { get async }

  /// The path to the raw index store data, if any.
  var indexStorePath: AbsolutePath? { get async }

  /// The path to put the index database, if any.
  var indexDatabasePath: AbsolutePath? { get async }

  /// Path remappings for remapping index data for local use.
  var indexPrefixMappings: [PathPrefixMapping] { get async }

  /// Delegate to handle any build system events such as file build settings initial reports as well as changes.
  ///
  /// The build system must not retain the delegate because the delegate can be the `BuildSystemManager`, which could
  /// result in a retain cycle `BuildSystemManager` -> `BuildSystem` -> `BuildSystemManager`.
  var delegate: BuildSystemDelegate? { get async }

  /// Set the build system's delegate.
  ///
  /// - Note: Needed so we can set the delegate from a different actor isolation
  ///   context.
  func setDelegate(_ delegate: BuildSystemDelegate?) async

  /// Retrieve build settings for the given document with the given source
  /// language.
  ///
  /// Returns `nil` if the build system can't provide build settings for this
  /// file or if it hasn't computed build settings for the file yet.
  func buildSettings(
    for document: DocumentURI,
    in target: ConfiguredTarget,
    language: Language
  ) async throws -> FileBuildSettings?

  /// Return the list of targets and run destinations that the given document can be built for.
  func configuredTargets(for document: DocumentURI) async -> [ConfiguredTarget]

  /// Re-generate the build graph including all the tasks that are necessary for building the entire build graph, like
  /// resolving package versions.
  func generateBuildGraph() async throws

  /// Sort the targets so that low-level targets occur before high-level targets.
  ///
  /// This sorting is best effort but allows the indexer to prepare and index low-level targets first, which allows
  /// index data to be available earlier.
  ///
  /// `nil` if the build system doesn't support topological sorting of targets.
  func topologicalSort(of targets: [ConfiguredTarget]) async -> [ConfiguredTarget]?

  /// Returns the list of targets that might depend on the given target and that need to be re-prepared when a file in
  /// `target` is modified.
  ///
  /// The returned list can be an over-approximation, in which case the indexer will perform more work than strictly
  /// necessary by scheduling re-preparation of a target where it isn't necessary.
  ///
  /// Returning `nil` indicates that all targets should be considered depending on the given target.
  func targets(dependingOn targets: [ConfiguredTarget]) async -> [ConfiguredTarget]?

  /// Prepare the given targets for indexing and semantic functionality. This should build all swift modules of target
  /// dependencies.
  func prepare(
    targets: [ConfiguredTarget],
    indexProcessDidProduceResult: @Sendable (IndexProcessResult) -> Void
  ) async throws

  /// If the build system has knowledge about the language that this document should be compiled in, return it.
  ///
  /// This is used to determine the language in which a source file should be background indexed.
  ///
  /// If `nil` is returned, the language based on the file's extension.
  func defaultLanguage(for document: DocumentURI) async -> Language?

  /// Register the given file for build-system level change notifications, such
  /// as command line flag changes, dependency changes, etc.
  ///
  /// IMPORTANT: When first receiving a register request, the `BuildSystem` MUST asynchronously
  /// inform its delegate of any initial settings for the given file via the
  /// `fileBuildSettingsChanged` method, even if unavailable.
  func registerForChangeNotifications(for: DocumentURI) async

  /// Unregister the given file for build-system level change notifications,
  /// such as command line flag changes, dependency changes, etc.
  func unregisterForChangeNotifications(for: DocumentURI) async

  /// Called when files in the project change.
  func filesDidChange(_ events: [FileEvent]) async

  func fileHandlingCapability(for uri: DocumentURI) async -> FileHandlingCapability

  /// Returns the list of source files in the project.
  ///
  /// Header files should not be considered as source files because they cannot be compiled.
  func sourceFiles() async -> [SourceFileInfo]

  /// Adds a callback that should be called when the value returned by `sourceFiles()` changes.
  ///
  /// The callback might also be called without an actual change to `sourceFiles`.
  func addSourceFilesDidChangeCallback(_ callback: @Sendable @escaping () async -> Void) async
}
