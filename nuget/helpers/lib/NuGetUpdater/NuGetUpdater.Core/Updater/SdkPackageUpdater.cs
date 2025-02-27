using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

using Microsoft.Build.Evaluation;
using Microsoft.Language.Xml;

using NuGet.Versioning;

namespace NuGetUpdater.Core;

internal static partial class SdkPackageUpdater
{
    public static async Task UpdateDependencyAsync(string repoRootPath, string projectPath, string dependencyName, string previousDependencyVersion, string newDependencyVersion, bool isTransitive, Logger logger)
    {
        // SDK-style project, modify the XML directly
        logger.Log("  Running for SDK-style project");
        var buildFiles = await MSBuildHelper.LoadBuildFiles(repoRootPath, projectPath);

        var newDependencyNuGetVersion = NuGetVersion.Parse(newDependencyVersion);

        // update all dependencies, including transitive
        var tfms = MSBuildHelper.GetTargetFrameworkMonikers(buildFiles);

        // Get the set of all top-level dependencies in the current project
        var topLevelDependencies = MSBuildHelper.GetTopLevelPackageDependenyInfos(buildFiles).ToArray();

        var packageFoundInDependencies = false;
        var packageNeedsUpdating = false;

        foreach (var tfm in tfms)
        {
            var dependencies = await MSBuildHelper.GetAllPackageDependenciesAsync(repoRootPath, projectPath, tfm, topLevelDependencies, logger);
            foreach (var (packageName, packageVersion, _, _, _) in dependencies)
            {
                if (packageName.Equals(dependencyName, StringComparison.OrdinalIgnoreCase))
                {
                    packageFoundInDependencies = true;

                    var nugetVersion = NuGetVersion.Parse(packageVersion);
                    if (nugetVersion < newDependencyNuGetVersion)
                    {
                        packageNeedsUpdating = true;
                    }
                }
            }
        }

        // Skip updating the project if the dependency does not exist in the graph
        if (!packageFoundInDependencies)
        {
            logger.Log($"    Package [{dependencyName}] Does not exist as a dependency in [{projectPath}].");
            return;
        }

        // Skip updating the project if the dependency version meets or exceeds the newDependencyVersion
        if (!packageNeedsUpdating)
        {
            logger.Log($"    Package [{dependencyName}] already meets the requested dependency version in [{projectPath}].");
            return;
        }

        var newDependency = new[] { new Dependency(dependencyName, newDependencyVersion, DependencyType.Unknown) };
        var tfmsAndDependencies = new Dictionary<string, Dependency[]>();
        foreach (var tfm in tfms)
        {
            var dependencies = await MSBuildHelper.GetAllPackageDependenciesAsync(repoRootPath, projectPath, tfm, newDependency, logger);
            tfmsAndDependencies[tfm] = dependencies;
        }

        // stop update process if we find conflicting package versions
        var conflictingPackageVersionsFound = false;
        var packagesAndVersions = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (tfm, dependencies) in tfmsAndDependencies)
        {
            foreach (var (packageName, packageVersion, _, _, _) in dependencies)
            {
                if (packagesAndVersions.TryGetValue(packageName, out var existingVersion) &&
                    existingVersion != packageVersion)
                {
                    logger.Log($"    Package [{packageName}] tried to update to version [{packageVersion}], but found conflicting package version of [{existingVersion}].");
                    conflictingPackageVersionsFound = true;
                }
                else
                {
                    packagesAndVersions[packageName] = packageVersion!;
                }
            }
        }

        if (conflictingPackageVersionsFound)
        {
            return;
        }

        var unupgradableTfms = tfmsAndDependencies.Where(kvp => !kvp.Value.Any()).Select(kvp => kvp.Key);
        if (unupgradableTfms.Any())
        {
            logger.Log($"    The following target frameworks could not find packages to upgrade: {string.Join(", ", unupgradableTfms)}");
            return;
        }

        if (isTransitive)
        {
            var directoryPackagesWithPinning = buildFiles.OfType<ProjectBuildFile>()
                .FirstOrDefault(bf => IsCpmTransitivePinningEnabled(bf));
            if (directoryPackagesWithPinning is not null)
            {
                PinTransitiveDependency(directoryPackagesWithPinning, dependencyName, newDependencyVersion, logger);
            }
            else
            {
                await AddTransitiveDependencyAsync(projectPath, dependencyName, newDependencyVersion, logger);
            }
        }
        else
        {
            await UpdateTopLevelDepdendencyAsync(buildFiles, dependencyName, previousDependencyVersion, newDependencyVersion, packagesAndVersions, logger);
        }

        var updatedTopLevelDependencies = MSBuildHelper.GetTopLevelPackageDependenyInfos(buildFiles);
        foreach (var tfm in tfms)
        {
            var updatedPackages = await MSBuildHelper.GetAllPackageDependenciesAsync(repoRootPath, projectPath, tfm, updatedTopLevelDependencies.ToArray(), logger);
            var dependenciesAreCoherent = await MSBuildHelper.DependenciesAreCoherentAsync(repoRootPath, projectPath, tfm, updatedPackages, logger);
            if (!dependenciesAreCoherent)
            {
                logger.Log($"    Package [{dependencyName}] could not be updated in [{projectPath}] because it would cause a dependency conflict.");
                return;
            }
        }

        foreach (var buildFile in buildFiles)
        {
            if (await buildFile.SaveAsync())
            {
                logger.Log($"    Saved [{buildFile.RepoRelativePath}].");
            }
        }
    }

    private static bool IsCpmTransitivePinningEnabled(ProjectBuildFile buildFile)
    {
        var buildFileName = Path.GetFileName(buildFile.Path);
        if (!buildFileName.Equals("Directory.Packages.props", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var propertyElements = buildFile.PropertyNodes;

        var isCpmEnabledValue = propertyElements.FirstOrDefault(e =>
            e.Name.Equals("ManagePackageVersionsCentrally", StringComparison.OrdinalIgnoreCase))?.GetContentValue();
        if (isCpmEnabledValue is null || !string.Equals(isCpmEnabledValue, "true", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var isTransitivePinningEnabled = propertyElements.FirstOrDefault(e =>
            e.Name.Equals("CentralPackageTransitivePinningEnabled", StringComparison.OrdinalIgnoreCase))?.GetContentValue();
        return isTransitivePinningEnabled is not null && string.Equals(isTransitivePinningEnabled, "true", StringComparison.OrdinalIgnoreCase);
    }

    private static void PinTransitiveDependency(ProjectBuildFile directoryPackages, string dependencyName, string newDependencyVersion, Logger logger)
    {
        var existingPackageVersionElement = directoryPackages.ItemNodes
            .Where(e => e.Name.Equals("PackageVersion", StringComparison.OrdinalIgnoreCase) &&
                        e.Attributes.Any(a => a.Name.Equals("Include", StringComparison.OrdinalIgnoreCase) &&
                                              a.Value.Equals(dependencyName, StringComparison.OrdinalIgnoreCase)))
            .FirstOrDefault();

        logger.Log($"    Pinning [{dependencyName}/{newDependencyVersion}] as a package version.");

        var lastPackageVersion = directoryPackages.ItemNodes
            .Where(e => e.Name.Equals("PackageVersion", StringComparison.OrdinalIgnoreCase))
            .LastOrDefault();

        if (lastPackageVersion is null)
        {
            logger.Log($"    Transitive dependency [{dependencyName}/{newDependencyVersion}] was not pinned.");
            return;
        }

        var lastItemGroup = lastPackageVersion.Parent;

        IXmlElementSyntax updatedItemGroup;
        if (existingPackageVersionElement is null)
        {
            // need to add a new entry
            logger.Log("      New PackageVersion element added.");
            var leadingTrivia = lastPackageVersion.AsNode.GetLeadingTrivia();
            var packageVersionElement = XmlExtensions.CreateSingleLineXmlElementSyntax("PackageVersion", new SyntaxList<SyntaxNode>(leadingTrivia))
                .WithAttribute("Include", dependencyName)
                .WithAttribute("Version", newDependencyVersion);
            updatedItemGroup = lastItemGroup.AddChild(packageVersionElement);
        }
        else
        {
            IXmlElementSyntax updatedPackageVersionElement;
            var versionAttribute = existingPackageVersionElement.Attributes.FirstOrDefault(a => a.Name.Equals("Version", StringComparison.OrdinalIgnoreCase));
            if (versionAttribute is null)
            {
                // need to add the version
                logger.Log("      Adding version attribute to element.");
                updatedPackageVersionElement = existingPackageVersionElement.WithAttribute("Version", newDependencyVersion);
            }
            else if (!versionAttribute.Value.Equals(newDependencyVersion, StringComparison.OrdinalIgnoreCase))
            {
                // need to update the version
                logger.Log($"      Updating version attribute of [{versionAttribute.Value}].");
                var updatedVersionAttribute = versionAttribute.WithValue(newDependencyVersion);
                updatedPackageVersionElement = existingPackageVersionElement.ReplaceAttribute(versionAttribute, updatedVersionAttribute);
            }
            else
            {
                logger.Log("      Existing PackageVersion element version was already correct.");
                return;
            }

            updatedItemGroup = lastItemGroup.ReplaceChildElement(existingPackageVersionElement, updatedPackageVersionElement);
        }

        var updatedXml = directoryPackages.Contents.ReplaceNode(lastItemGroup.AsNode, updatedItemGroup.AsNode);
        directoryPackages.Update(updatedXml);
    }

    private static async Task AddTransitiveDependencyAsync(string projectPath, string dependencyName, string newDependencyVersion, Logger logger)
    {
        logger.Log($"    Adding [{dependencyName}/{newDependencyVersion}] as a top-level package reference.");

        // see https://learn.microsoft.com/nuget/consume-packages/install-use-packages-dotnet-cli
        var (exitCode, _, _) = await ProcessEx.RunAsync("dotnet", $"add {projectPath} package {dependencyName} --version {newDependencyVersion}");
        if (exitCode != 0)
        {
            logger.Log($"    Transitive dependency [{dependencyName}/{newDependencyVersion}] was not added.");
        }
    }

    private static async Task UpdateTopLevelDepdendencyAsync(ImmutableArray<ProjectBuildFile> buildFiles, string dependencyName, string previousDependencyVersion, string newDependencyVersion, Dictionary<string, string> packagesAndVersions, Logger logger)
    {
        var result = TryUpdateDependencyVersion(buildFiles, dependencyName, previousDependencyVersion, newDependencyVersion, logger);
        if (result == UpdateResult.NotFound)
        {
            logger.Log($"    Root package [{dependencyName}/{previousDependencyVersion}] was not updated; skipping dependencies.");
            return;
        }

        foreach (var (packageName, packageVersion) in packagesAndVersions.Where(kvp => string.Compare(kvp.Key, dependencyName, StringComparison.OrdinalIgnoreCase) != 0))
        {
            TryUpdateDependencyVersion(buildFiles, packageName, previousDependencyVersion: null, newDependencyVersion: packageVersion, logger);
        }
    }

    private static UpdateResult TryUpdateDependencyVersion(ImmutableArray<ProjectBuildFile> buildFiles, string dependencyName, string? previousDependencyVersion, string newDependencyVersion, Logger logger)
    {
        var foundCorrect = false;
        var foundUnsupported = false;
        var updateWasPerformed = false;
        var propertyNames = new List<string>();

        // First we locate all the PackageReference, GlobalPackageReference, or PackageVersion which set the Version
        // or VersionOverride attribute. In the simplest case we can update the version attribute directly then move
        // on. When property substitution is used we have to additionally search for the property containing the version.

        foreach (var buildFile in buildFiles)
        {
            var updateNodes = new List<XmlNodeSyntax>();
            var packageNodes = FindPackageNodes(buildFile, dependencyName);

            var previousPackageVersion = previousDependencyVersion;

            foreach (var packageNode in packageNodes)
            {
                var versionAttribute = packageNode.GetAttribute("Version", StringComparison.OrdinalIgnoreCase)
                    ?? packageNode.GetAttribute("VersionOverride", StringComparison.OrdinalIgnoreCase);
                var versionElement = packageNode.Elements.FirstOrDefault(e => e.Name.Equals("Version", StringComparison.OrdinalIgnoreCase))
                    ?? packageNode.Elements.FirstOrDefault(e => e.Name.Equals("VersionOverride", StringComparison.OrdinalIgnoreCase));
                if (versionAttribute is not null)
                {
                    // Is this the case where version is specified with property substitution?
                    if (MSBuildHelper.TryGetPropertyName(versionAttribute.Value, out var propertyName))
                    {
                        propertyNames.Add(propertyName);
                    }
                    // Is this the case that the version is specified directly in the package node?
                    else
                    {
                        var currentVersion = versionAttribute.Value.TrimStart('[', '(').TrimEnd(']', ')');
                        if (currentVersion.Contains(',') || currentVersion.Contains('*'))
                        {
                            logger.Log($"    Found unsupported [{packageNode.Name}] version attribute value [{versionAttribute.Value}] in [{buildFile.RepoRelativePath}].");
                            foundUnsupported = true;
                        }
                        else if (string.Equals(currentVersion, previousDependencyVersion, StringComparison.Ordinal))
                        {
                            logger.Log($"    Found incorrect [{packageNode.Name}] version attribute in [{buildFile.RepoRelativePath}].");
                            updateNodes.Add(versionAttribute);
                        }
                        else if (previousDependencyVersion == null && NuGetVersion.TryParse(currentVersion, out var previousVersion))
                        {
                            var newVersion = NuGetVersion.Parse(newDependencyVersion);
                            if (previousVersion < newVersion)
                            {
                                previousPackageVersion = currentVersion;

                                logger.Log($"    Found incorrect peer [{packageNode.Name}] version attribute in [{buildFile.RepoRelativePath}].");
                                updateNodes.Add(versionAttribute);
                            }
                        }
                        else if (string.Equals(currentVersion, newDependencyVersion, StringComparison.Ordinal))
                        {
                            logger.Log($"    Found correct [{packageNode.Name}] version attribute in [{buildFile.RepoRelativePath}].");
                            foundCorrect = true;
                        }
                    }
                }
                else if (versionElement is not null)
                {
                    var versionValue = versionElement.GetContentValue();
                    if (MSBuildHelper.TryGetPropertyName(versionValue, out var propertyName))
                    {
                        propertyNames.Add(propertyName);
                    }
                    else
                    {
                        var currentVersion = versionValue.TrimStart('[', '(').TrimEnd(']', ')');
                        if (currentVersion.Contains(',') || currentVersion.Contains('*'))
                        {
                            logger.Log($"    Found unsupported [{packageNode.Name}] version node value [{versionValue}] in [{buildFile.RepoRelativePath}].");
                            foundUnsupported = true;
                        }
                        else if (currentVersion == previousDependencyVersion)
                        {
                            logger.Log($"    Found incorrect [{packageNode.Name}] version node in [{buildFile.RepoRelativePath}].");
                            if (versionElement is XmlElementSyntax elementSyntax)
                            {
                                updateNodes.Add(elementSyntax);
                            }
                            else
                            {
                                throw new InvalidDataException("A concrete type was required for updateNodes. This should not happen.");
                            }
                        }
                        else if (previousDependencyVersion == null && NuGetVersion.TryParse(currentVersion, out var previousVersion))
                        {
                            var newVersion = NuGetVersion.Parse(newDependencyVersion);
                            if (previousVersion < newVersion)
                            {
                                previousPackageVersion = currentVersion;

                                logger.Log($"    Found incorrect peer [{packageNode.Name}] version node in [{buildFile.RepoRelativePath}].");
                                if (versionElement is XmlElementSyntax elementSyntax)
                                {
                                    updateNodes.Add(elementSyntax);
                                }
                                else
                                {
                                    // This only exists for completeness in case we ever add a new type of node we don't want to silently ignore them.
                                    throw new InvalidDataException("A concrete type was required for updateNodes. This should not happen.");
                                }
                            }
                        }
                        else if (currentVersion == newDependencyVersion)
                        {
                            logger.Log($"    Found correct [{packageNode.Name}] version node in [{buildFile.RepoRelativePath}].");
                            foundCorrect = true;
                        }
                    }
                }
                else
                {
                    // We weren't able to find the version node. Central package management?
                    logger.Log($"    Found package reference but was unable to locate version information.");
                    continue;
                }
            }

            if (updateNodes.Count > 0)
            {
                var updatedXml = buildFile.Contents
                    .ReplaceNodes(updateNodes, (o, n) =>
                    {
                        if (n is XmlAttributeSyntax attributeSyntax)
                        {
                            return attributeSyntax.WithValue(attributeSyntax.Value.Replace(previousPackageVersion!, newDependencyVersion));
                        }
                        else if (n is XmlElementSyntax elementsSyntax)
                        {
                            var modifiedContent = elementsSyntax.GetContentValue().Replace(previousPackageVersion!, newDependencyVersion);

                            var textSyntax = SyntaxFactory.XmlText(SyntaxFactory.Token(null, SyntaxKind.XmlTextLiteralToken, null, modifiedContent));
                            return elementsSyntax.WithContent(SyntaxFactory.SingletonList(textSyntax));
                        }
                        else
                        {
                            throw new InvalidDataException($"Unsupported SyntaxType {n.GetType().Name} marked for update");
                        }
                    });
                buildFile.Update(updatedXml);
                updateWasPerformed = true;
            }
        }

        // If property substitution was used to set the Version, we must search for the property containing
        // the version string. Since it could also be populated by property substitution this search repeats
        // with the each new property name until the version string is located.

        var processedPropertyNames = new HashSet<string>();

        for (int propertyNameIndex = 0; propertyNameIndex < propertyNames.Count; propertyNameIndex++)
        {
            var propertyName = propertyNames[propertyNameIndex];
            if (processedPropertyNames.Contains(propertyName))
            {
                continue;
            }

            processedPropertyNames.Add(propertyName);

            foreach (var buildFile in buildFiles)
            {
                var updateProperties = new List<XmlElementSyntax>();
                var propertyElements = buildFile.PropertyNodes
                    .Where(e => e.Name.Equals(propertyName, StringComparison.OrdinalIgnoreCase));

                var previousPackageVersion = previousDependencyVersion;

                foreach (var propertyElement in propertyElements)
                {
                    var propertyContents = propertyElement.GetContentValue();

                    // Is this the case where this property contains another property substitution?
                    if (MSBuildHelper.TryGetPropertyName(propertyContents, out var propName))
                    {
                        propertyNames.Add(propName);
                    }
                    // Is this the case that the property contains the version?
                    else
                    {
                        var currentVersion = propertyContents.TrimStart('[', '(').TrimEnd(']', ')');
                        if (currentVersion.Contains(',') || currentVersion.Contains('*'))
                        {
                            logger.Log($"    Found unsupported version property [{propertyElement.Name}] value [{propertyContents}] in [{buildFile.RepoRelativePath}].");
                            foundUnsupported = true;
                        }
                        else if (currentVersion == previousDependencyVersion)
                        {
                            logger.Log($"    Found incorrect version property [{propertyElement.Name}] in [{buildFile.RepoRelativePath}].");
                            updateProperties.Add((XmlElementSyntax)propertyElement.AsNode);
                        }
                        else if (previousDependencyVersion is null && NuGetVersion.TryParse(currentVersion, out var previousVersion))
                        {
                            var newVersion = NuGetVersion.Parse(newDependencyVersion);
                            if (previousVersion < newVersion)
                            {
                                previousPackageVersion = currentVersion;

                                logger.Log($"    Found incorrect peer version property [{propertyElement.Name}] in [{buildFile.RepoRelativePath}].");
                                updateProperties.Add((XmlElementSyntax)propertyElement.AsNode);
                            }
                        }
                        else if (currentVersion == newDependencyVersion)
                        {
                            logger.Log($"    Found correct version property [{propertyElement.Name}] in [{buildFile.RepoRelativePath}].");
                            foundCorrect = true;
                        }
                    }
                }

                if (updateProperties.Count > 0)
                {
                    var updatedXml = buildFile.Contents
                        .ReplaceNodes(updateProperties, (o, n) => n.WithContent(o.GetContentValue().Replace(previousPackageVersion!, newDependencyVersion)).AsNode);
                    buildFile.Update(updatedXml);
                    updateWasPerformed = true;
                }
            }
        }

        return updateWasPerformed
            ? UpdateResult.Updated
            : foundCorrect
                ? UpdateResult.Correct
                : foundUnsupported
                    ? UpdateResult.NotSupported
                    : UpdateResult.NotFound;
    }

    private static IEnumerable<IXmlElementSyntax> FindPackageNodes(ProjectBuildFile buildFile, string packageName)
    {
        return buildFile.PackageItemNodes.Where(e =>
            string.Equals(e.GetAttributeOrSubElementValue("Include", StringComparison.OrdinalIgnoreCase) ?? e.GetAttributeOrSubElementValue("Update", StringComparison.OrdinalIgnoreCase), packageName, StringComparison.OrdinalIgnoreCase) &&
            (e.GetAttributeOrSubElementValue("Version", StringComparison.OrdinalIgnoreCase) ?? e.GetAttributeOrSubElementValue("VersionOverride", StringComparison.OrdinalIgnoreCase)) is not null);
    }
}
