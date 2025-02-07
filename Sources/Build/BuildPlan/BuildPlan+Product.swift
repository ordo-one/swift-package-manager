//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Basics.AbsolutePath
import struct Basics.Triple
import struct Basics.InternalError
import struct PackageGraph.ResolvedProduct
import struct PackageGraph.ResolvedTarget
import class PackageModel.BinaryTarget
import class PackageModel.ClangTarget

import class PackageModel.Target

import class PackageModel.SwiftTarget
import class PackageModel.SystemLibraryTarget
import struct SPMBuildCore.BuildParameters
import struct SPMBuildCore.ExecutableInfo
import func TSCBasic.topologicalSort

extension BuildPlan {
    /// Plan a product.
    func plan(buildProduct: ProductBuildDescription) throws {
        // Compute the product's dependency.
        let dependencies = try computeDependencies(
            of: buildProduct.product,
            buildParameters: buildProduct.buildParameters
        )

        // Add flags for system targets.
        for systemModule in dependencies.systemModules {
            guard case let target as SystemLibraryTarget = systemModule.underlying else {
                throw InternalError("This should not be possible.")
            }
            // Add pkgConfig libs arguments.
            buildProduct.additionalFlags += try pkgConfig(for: target).libs
        }

        // Add flags for binary dependencies.
        var dynamicLibraries: Set<Substring> = []
        for binaryPath in dependencies.sharedLibraryBinaries {
            if binaryPath.basename.starts(with: "lib"), binaryPath.extension == "so" {
                buildProduct.additionalFlags += ["-L", binaryPath.parentDirectory.pathString]
                dynamicLibraries.insert(binaryPath.basenameWithoutExt.dropFirst(3))
            } else {
                self.observabilityScope.emit(error: "unexpected binary library")
            }
        }
        for binaryPath in dependencies.xcframeworkBinaries {
            if binaryPath.extension == "framework" {
                buildProduct.additionalFlags += ["-framework", binaryPath.basenameWithoutExt]
            } else if binaryPath.basename.starts(with: "lib") {
                dynamicLibraries.insert(binaryPath.basenameWithoutExt.dropFirst(3))
            } else {
                self.observabilityScope.emit(error: "unexpected binary framework")
            }
        }
        for dynamicLibrary: Substring in dynamicLibraries {
            buildProduct.additionalFlags += ["-l\(dynamicLibrary)"]
        }

        // Don't link libc++ or libstd++ when building for Embedded Swift.
        // Users can still link it manually for embedded platforms when needed,
        // by providing `-Xlinker -lc++` options via CLI or `Package.swift`.
        if !buildProduct.product.targets.contains(where: \.underlying.isEmbeddedSwiftTarget) {
            // Link C++ if needed.
            // Note: This will come from build settings in future.
            for target in dependencies.staticTargets {
                if case let target as ClangTarget = target.underlying, target.isCXX {
                    let triple = buildProduct.buildParameters.triple
                    if triple.isDarwin() {
                        buildProduct.additionalFlags += ["-lc++"]
                    } else if triple.isWindows() {
                        // Don't link any C++ library.
                    } else {
                        buildProduct.additionalFlags += ["-lstdc++"]
                    }
                    break
                }
            }
        }

        for target in dependencies.staticTargets {
            switch target.underlying {
            case is SwiftTarget:
                // Swift targets are guaranteed to have a corresponding Swift description.
                guard case .swift(let description) = targetMap[target.id] else {
                    throw InternalError("unknown target \(target)")
                }

                // Based on the debugging strategy, we either need to pass swiftmodule paths to the
                // product or link in the wrapped module object. This is required for properly debugging
                // Swift products. Debugging strategy is computed based on the current platform we're
                // building for and is nil for the release configuration.
                switch buildProduct.buildParameters.debuggingStrategy {
                case .swiftAST:
                    buildProduct.swiftASTs.insert(description.moduleOutputPath)
                case .modulewrap:
                    buildProduct.objects += [description.wrappedModuleOutputPath]
                case nil:
                    break
                }
            default: break
            }
        }

        buildProduct.staticTargets = dependencies.staticTargets.map(\.module)
        buildProduct.dylibs = dependencies.dylibs
        buildProduct.objects += try dependencies.staticTargets.flatMap { try $0.objects }
        buildProduct.libraryBinaryPaths = dependencies.xcframeworkBinaries
        buildProduct.availableTools = dependencies.availableTools
    }

    /// Computes the dependencies of a product.
    private func computeDependencies(
        of product: ResolvedProduct,
        buildParameters: BuildParameters
    ) throws -> (
        dylibs: [ProductBuildDescription],
        staticTargets: [ModuleBuildDescription],
        systemModules: [ResolvedModule],
        sharedLibraryBinaries: Set<AbsolutePath>,
        xcframeworkBinaries: Set<AbsolutePath>,
        availableTools: [String: AbsolutePath]
    ) {
        /* Prior to tools-version 5.9, we used to erroneously recursively traverse executable/plugin dependencies and statically include their
         targets. For compatibility reasons, we preserve that behavior for older tools-versions. */
        let shouldExcludePlugins: Bool
        if let toolsVersion = self.graph.package(for: product)?.manifest.toolsVersion {
            shouldExcludePlugins = toolsVersion >= .v5_9
        } else {
            shouldExcludePlugins = false
        }

        // For test targets, we need to consider the first level of transitive dependencies since the first level is always test targets.
        let topLevelDependencies: [PackageModel.Target]
        if product.type == .test {
            topLevelDependencies = product.targets.flatMap { $0.underlying.dependencies }.compactMap {
                switch $0 {
                case .product:
                    return nil
                case .target(let target, _):
                    return target
                }
            }
        } else {
            topLevelDependencies = []
        }

        // get the dynamic libraries for explicitly linking rdar://108561857
        func recursiveDynamicLibraries(for product: ResolvedProduct) throws -> [ResolvedProduct] {
            let dylibs = try computeDependencies(of: product, buildParameters: buildParameters).dylibs
            return try dylibs + dylibs.flatMap { try recursiveDynamicLibraries(for: $0) }
        }

        // Sort the product targets in topological order.
        let nodes: [ResolvedTarget.Dependency] = product.targets.map { .target($0, conditions: []) }
        let allTargets = try topologicalSort(nodes, successors: { dependency in
            switch dependency {
            // Include all the dependencies of a target.
            case .target(let target, _):
                let isTopLevel = topLevelDependencies.contains(target.underlying) || product.targets.contains(id: target.id)
                let topLevelIsMacro = isTopLevel && product.type == .macro
                let topLevelIsPlugin = isTopLevel && product.type == .plugin
                let topLevelIsTest = isTopLevel && product.type == .test

                if !topLevelIsMacro && !topLevelIsTest && target.type == .macro {
                    return []
                }
                if shouldExcludePlugins, !topLevelIsPlugin && !topLevelIsTest && target.type == .plugin {
                    return []
                }
                return target.dependencies.filter { $0.satisfies(buildParameters.buildEnvironment) }

            // For a product dependency, we only include its content only if we
            // need to statically link it.
            case .product(let product, _):
                guard dependency.satisfies(buildParameters.buildEnvironment) else {
                    return []
                }

                let productDependencies: [ResolvedTarget.Dependency] = product.targets.map { .target($0, conditions: []) }
                switch product.type {
                case .library(.automatic), .library(.static):
                    return productDependencies
                case .plugin:
                    return shouldExcludePlugins ? [] : productDependencies
                case .library(.dynamic):
                    return try recursiveDynamicLibraries(for: product).map { .product($0, conditions: []) }
                case .test, .executable, .snippet, .macro:
                    return []
                }
            }
        })

        // Create empty arrays to collect our results.
<<<<<<< HEAD
        var linkLibraries = [ResolvedProduct]()
        var staticTargets = [ResolvedTarget]()
        var systemModules = [ResolvedTarget]()
        var libraryBinaryPaths: Set<AbsolutePath> = []
=======
        var linkLibraries = [ProductBuildDescription]()
        var staticTargets = [ModuleBuildDescription]()
        var systemModules = [ResolvedModule]()
        var sharedLibraryBinaries: Set<AbsolutePath> = []
        var xcframeworkBinaries: Set<AbsolutePath> = []
>>>>>>> d01f6ba5e (automatically populate linker flags for dynamic library dependencies)
        var availableTools = [String: AbsolutePath]()

        for dependency in allTargets {
            switch dependency {
            case .target(let target, _):
                switch target.type {
                // Executable target have historically only been included if they are directly in the product's
                // target list.  Otherwise they have always been just build-time dependencies.
                // In tool version .v5_5 or greater, we also include executable modules implemented in Swift in
                // any test products... this is to allow testing of executables.  Note that they are also still
                // built as separate products that the test can invoke as subprocesses.
                case .executable, .snippet, .macro:
                    if product.targets.contains(id: target.id) {
                        staticTargets.append(target)
                    } else if product.type == .test && (target.underlying as? SwiftTarget)?.supportsTestableExecutablesFeature == true {
                        // Only "top-level" targets should really be considered here, not transitive ones.
                        let isTopLevel = topLevelDependencies.contains(target.underlying) || product.targets.contains(id: target.id)
                        if let toolsVersion = graph.package(for: product)?.manifest.toolsVersion, toolsVersion >= .v5_5, isTopLevel {
                            staticTargets.append(target)
                        }
                    }
                // Test targets should be included only if they are directly in the product's target list.
                case .test:
                    if product.targets.contains(id: target.id) {
                        staticTargets.append(target)
                    }
                // Library targets should always be included.
                case .library:
                    staticTargets.append(target)
                // Add system target to system targets array.
                case .systemModule:
                    systemModules.append(target)
                // Add binary to binary paths set.
                case .binary:
                    guard let binaryTarget = target.underlying as? BinaryTarget else {
                        throw InternalError("invalid binary target '\(target.name)'")
                    }
                    switch binaryTarget.kind {
                    case .xcframework:
                        let libraries = try self.parseXCFramework(for: binaryTarget, triple: buildParameters.triple)
                        for library in libraries {
                            xcframeworkBinaries.insert(library.libraryPath)
                        }
                    case .artifactsArchive:
<<<<<<< HEAD
                        let tools = try self.parseArtifactsArchive(for: binaryTarget, triple: buildParameters.triple)
                        tools.forEach { availableTools[$0.name] = $0.executablePath  }
                    case.unknown:
                        throw InternalError("unknown binary target '\(target.name)' type")
=======
                        let libraries = try self.parseLibraries(
                            in: binaryTarget, triple: productDescription.buildParameters.triple
                        )
                        for library in libraries {
                            sharedLibraryBinaries.insert(library.libraryPath)
                        }
                        let tools = try self.parseExecutables(
                            in: binaryTarget, triple: productDescription.buildParameters.triple
                        )
                        tools.forEach { availableTools[$0.name] = $0.executablePath }
                    case .unknown:
                        throw InternalError("unknown binary target '\(module.name)' type")
>>>>>>> d01f6ba5e (automatically populate linker flags for dynamic library dependencies)
                    }
                case .plugin:
                    continue
                }

            case .product(let product, _):
                // Add the dynamic products to array of libraries to link.
                if product.type == .library(.dynamic) {
                    linkLibraries.append(product)
                }
            }
        }

        // Add derived test targets, if necessary
        if buildParameters.testingParameters.testProductStyle.requiresAdditionalDerivedTestTargets {
            if product.type == .test, let derivedTestTargets = derivedTestTargetsMap[product.id] {
                staticTargets.append(contentsOf: derivedTestTargets)
            }
        }

<<<<<<< HEAD
        return (linkLibraries, staticTargets, systemModules, libraryBinaryPaths, availableTools)
    }

    /// Extracts the artifacts  from an artifactsArchive
    private func parseArtifactsArchive(for binaryTarget: BinaryTarget, triple: Triple) throws -> [ExecutableInfo] {
        try self.externalExecutablesCache.memoize(key: binaryTarget) {
            let execInfos = try binaryTarget.parseArtifactArchives(for: triple, fileSystem: self.fileSystem)
            return execInfos.filter{!$0.supportedTriples.isEmpty}
        }
=======
        return (linkLibraries, staticTargets, systemModules, sharedLibraryBinaries, xcframeworkBinaries, availableTools)
>>>>>>> d01f6ba5e (automatically populate linker flags for dynamic library dependencies)
    }
}
