using System.Collections.Immutable;
using System.Text;
using System.Text.Json;

using NuGetUpdater.Core.Analyze;
using NuGetUpdater.Core.Discover;
using NuGetUpdater.Core.Run;
using NuGetUpdater.Core.Run.ApiModel;
using NuGetUpdater.Core.Test.Update;

using Xunit;

namespace NuGetUpdater.Core.Test.Run;

using TestFile = (string Path, string Content);
using RawTestFile = (string Path, byte[] Content);

public class EndToEndTests
{
    [Fact]
    public async Task WithPackageReference()
    {
        await RunAsync(
            packages: [
                MockNuGetPackage.CreateSimplePackage("Some.Package", "1.0.0", "net9.0"),
                MockNuGetPackage.CreateSimplePackage("Some.Package", "2.0.0", "net9.0"),
            ],
            job: new()
            {
                Source = new()
                {
                    Provider = "github",
                    Repo = "test/repo",
                    Directory = "/",
                }
            },
            files: [
                ("Directory.Build.props", "<Project />"),
                ("Directory.Build.targets", "<Project />"),
                ("Directory.Packages.props", """
                    <Project>
                      <PropertyGroup>
                        <ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally>
                      </PropertyGroup>
                    </Project>
                    """),
                ("project.csproj", """
                    <Project Sdk="Microsoft.NET.Sdk">
                      <PropertyGroup>
                        <TargetFramework>net9.0</TargetFramework>
                      </PropertyGroup>
                      <ItemGroup>
                        <PackageReference Include="Some.Package" Version="1.0.0" />
                      </ItemGroup>
                    </Project>
                    """)
            ],
            discoveryWorker: null, // use real worker
            analyzeWorker: null, // use real worker
            updaterWorker: null, // use real worker
            expectedApiMessages: [
                new IncrementMetric()
                {
                    Metric = "updater.started",
                    Tags = new()
                    {
                        ["operation"] = "group_update_all_versions"
                    }
                },
                new UpdatedDependencyList()
                {
                    Dependencies = [
                        new()
                        {
                            Name = "Some.Package",
                            Version = "1.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "1.0.0",
                                    File = "/project.csproj",
                                    Groups = ["dependencies"],
                                }
                            ]
                        },
                    ],
                    DependencyFiles = [
                        "/Directory.Build.props",
                        "/Directory.Build.targets",
                        "/Directory.Packages.props",
                        "/project.csproj",
                    ],
                },
                new CreatePullRequest()
                {
                    Dependencies = [
                        new()
                        {
                            Name = "Some.Package",
                            Version = "2.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "2.0.0",
                                    File = "/project.csproj",
                                    Groups = ["dependencies"],
                                    Source = new()
                                    {
                                        SourceUrl = null,
                                        Type = "nuget_repo",
                                    }
                                }
                            ],
                            PreviousVersion = "1.0.0",
                            PreviousRequirements = [
                                new()
                                {
                                    Requirement = "1.0.0",
                                    File = "/project.csproj",
                                    Groups = ["dependencies"],
                                }
                            ],
                        },
                    ],
                    UpdatedDependencyFiles = [
                        new()
                        {
                            Directory = "/",
                            Name = "project.csproj",
                            Content = """
                                <Project Sdk="Microsoft.NET.Sdk">
                                  <PropertyGroup>
                                    <TargetFramework>net9.0</TargetFramework>
                                  </PropertyGroup>
                                  <ItemGroup>
                                    <PackageReference Include="Some.Package" Version="2.0.0" />
                                  </ItemGroup>
                                </Project>
                                """
                        },
                    ],
                    BaseCommitSha = "TEST-COMMIT-SHA",
                    CommitMessage = TestPullRequestCommitMessage,
                    PrTitle = TestPullRequestTitle,
                    PrBody = TestPullRequestBody,
                    DependencyGroup = null,
                },
                new MarkAsProcessed("TEST-COMMIT-SHA")
            ]
        );
    }

    [Fact]
    public async Task WithPackagesConfig()
    {
        await RunAsync(
            packages: [
                MockNuGetPackage.CreateSimplePackage("Some.Package", "1.0.0", "net45"),
                MockNuGetPackage.CreateSimplePackage("Some.Package", "2.0.0", "net45"),
            ],
            job: new()
            {
                Source = new()
                {
                    Provider = "github",
                    Repo = "test/repo",
                    Directory = "/src",
                }
            },
            files: [
                ("src/packages.config", """
                    <?xml version="1.0" encoding="utf-8"?>
                    <packages>
                      <package id="Some.Package" version="1.0.0" targetFramework="net45" />
                    </packages>
                    """),
                ("src/project.csproj", """
                    <Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
                      <Import Project="$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props" Condition="Exists('$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props')" />
                      <PropertyGroup>
                        <TargetFrameworkVersion>v4.5</TargetFrameworkVersion>
                      </PropertyGroup>
                      <ItemGroup>
                        <None Include="packages.config" />
                      </ItemGroup>
                      <ItemGroup>
                        <Reference Include="Some.Package">
                          <HintPath>packages\Some.Package.1.0.0\lib\net45\Some.Package.dll</HintPath>
                          <Private>True</Private>
                        </Reference>
                      </ItemGroup>
                      <Import Project="$(MSBuildToolsPath)\Microsoft.CSharp.targets" />
                    </Project>
                    """),
                // due to weirdness in the testing setup, we need to ensure sdk-style crawling doesn't escape
                ("Directory.Build.props", "<Project />"),
                ("Directory.Build.targets", "<Project />"),
                ("Directory.Packages.props", """
                    <Project>
                      <PropertyGroup>
                        <ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally>
                      </PropertyGroup>
                    </Project>
                    """),
            ],
            discoveryWorker: null, // use real worker
            analyzeWorker: null, // use real worker
            updaterWorker: null, // use real worker
            expectedApiMessages: [
                new IncrementMetric()
                {
                    Metric = "updater.started",
                    Tags = new()
                    {
                        ["operation"] = "group_update_all_versions"
                    }
                },
                new UpdatedDependencyList()
                {
                    Dependencies = [
                        new()
                        {
                            Name = "Some.Package",
                            Version = "1.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "1.0.0",
                                    File = "/src/project.csproj",
                                    Groups = ["dependencies"],
                                }
                            ]
                        },
                    ],
                    DependencyFiles = [
                        "/src/packages.config",
                        "/src/project.csproj",
                    ],
                },
                new CreatePullRequest()
                {
                    Dependencies = [
                        new()
                        {
                            Name = "Some.Package",
                            Version = "2.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "2.0.0",
                                    File = "/src/project.csproj",
                                    Groups = ["dependencies"],
                                    Source = new()
                                    {
                                        SourceUrl = null,
                                        Type = "nuget_repo",
                                    }
                                }
                            ],
                            PreviousVersion = "1.0.0",
                            PreviousRequirements = [
                                new()
                                {
                                    Requirement = "1.0.0",
                                    File = "/src/project.csproj",
                                    Groups = ["dependencies"],
                                }
                            ],
                        },
                    ],
                    UpdatedDependencyFiles = [
                        new()
                        {
                            Directory = "/src",
                            Name = "packages.config",
                            Content = """
                                <?xml version="1.0" encoding="utf-8"?>
                                <packages>
                                  <package id="Some.Package" version="2.0.0" targetFramework="net45" />
                                </packages>
                                """
                        },
                        new()
                        {
                            Directory = "/src",
                            Name = "project.csproj",
                            Content = """
                                <Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
                                  <Import Project="$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props" Condition="Exists('$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props')" />
                                  <PropertyGroup>
                                    <TargetFrameworkVersion>v4.5</TargetFrameworkVersion>
                                  </PropertyGroup>
                                  <ItemGroup>
                                    <None Include="packages.config" />
                                  </ItemGroup>
                                  <ItemGroup>
                                    <Reference Include="Some.Package">
                                      <HintPath>packages\Some.Package.2.0.0\lib\net45\Some.Package.dll</HintPath>
                                      <Private>True</Private>
                                    </Reference>
                                  </ItemGroup>
                                  <Import Project="$(MSBuildToolsPath)\Microsoft.CSharp.targets" />
                                </Project>
                                """
                        },
                    ],
                    BaseCommitSha = "TEST-COMMIT-SHA",
                    CommitMessage = TestPullRequestCommitMessage,
                    PrTitle = TestPullRequestTitle,
                    PrBody = TestPullRequestBody,
                    DependencyGroup = null,
                },
                new MarkAsProcessed("TEST-COMMIT-SHA")
            ]
        );
    }

    [Fact]
    public async Task LegacyProject_With_PackageReference()
    {
        var experimentsManager = new ExperimentsManager();
        await RunAsync(
            experimentsManager: experimentsManager,
            packages: [
                MockNuGetPackage.CreateSimplePackage("Some.Package", "1.0.0", "net45"),
                MockNuGetPackage.CreateSimplePackage("Some.Package", "2.0.0", "net45"),
            ],
            job: new()
            {
                Source = new()
                {
                    Provider = "github",
                    Repo = "test/repo",
                    Directory = "/",
                }
            },
            files: [
                ("Directory.Build.props", "<Project />"),
                ("Directory.Build.targets", "<Project />"),
                ("Directory.Packages.props", """
                    <Project>
                      <PropertyGroup>
                        <ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally>
                      </PropertyGroup>
                    </Project>
                    """),
                ("project.csproj", """
                    <Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
                      <Import Project="$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props" Condition="Exists('$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props')" />
                      <PropertyGroup>
                        <OutputType>Library</OutputType>
                        <TargetFrameworkVersion>v4.5</TargetFrameworkVersion>
                      </PropertyGroup>
                      <ItemGroup>
                        <PackageReference Include="Some.Package" Version="1.0.0" />
                      </ItemGroup>
                      <Import Project="$(MSBuildToolsPath)\Microsoft.CSharp.targets" />
                    </Project>
                    """),
            ],
            discoveryWorker: new TestDiscoveryWorker(async args =>
            {
                // wrap real worker, but remove ref assemblies package to make testing more deterministic
                var (repoRootPath, workspacePath) = args;
                var worker = new DiscoveryWorker("TEST-JOB-ID", experimentsManager, new TestLogger());
                var discoveryResult = await worker.RunAsync(repoRootPath, workspacePath);
                return new()
                {
                    DotNetToolsJson = discoveryResult.DotNetToolsJson,
                    Error = discoveryResult.Error,
                    GlobalJson = discoveryResult.GlobalJson,
                    IsSuccess = discoveryResult.IsSuccess,
                    Path = discoveryResult.Path,
                    Projects = discoveryResult.Projects.Select(p => new ProjectDiscoveryResult()
                    {
                        AdditionalFiles = p.AdditionalFiles,
                        Dependencies = [.. p.Dependencies.Where(d => d.Name != "Microsoft.NETFramework.ReferenceAssemblies")],
                        Error = p.Error,
                        FilePath = p.FilePath,
                        ImportedFiles = p.ImportedFiles,
                        IsSuccess = p.IsSuccess,
                        Properties = p.Properties,
                        ReferencedProjectPaths = p.ReferencedProjectPaths,
                        TargetFrameworks = p.TargetFrameworks,
                    }).ToImmutableArray()
                };
            }),
            analyzeWorker: null, // use real worker
            updaterWorker: null, // use real worker
            expectedApiMessages: [
                new IncrementMetric()
                {
                    Metric = "updater.started",
                    Tags = new()
                    {
                        ["operation"] = "group_update_all_versions"
                    }
                },
                new UpdatedDependencyList()
                {
                    Dependencies = [
                        new()
                        {
                            Name = "Some.Package",
                            Version = "1.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "1.0.0",
                                    File = "/project.csproj",
                                    Groups = ["dependencies"],
                                }
                            ]
                        },
                    ],
                    DependencyFiles = [
                        "/Directory.Build.props",
                        "/Directory.Build.targets",
                        "/Directory.Packages.props",
                        "/project.csproj",
                    ],
                },
                new CreatePullRequest()
                {
                    Dependencies = [
                        new()
                        {
                            Name = "Some.Package",
                            Version = "2.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "2.0.0",
                                    File = "/project.csproj",
                                    Groups = ["dependencies"],
                                    Source = new()
                                    {
                                        SourceUrl = null,
                                        Type = "nuget_repo",
                                    }
                                }
                            ],
                            PreviousVersion = "1.0.0",
                            PreviousRequirements = [
                                new()
                                {
                                    Requirement = "1.0.0",
                                    File = "/project.csproj",
                                    Groups = ["dependencies"],
                                }
                            ],
                        },
                    ],
                    UpdatedDependencyFiles = [
                        new()
                        {
                            Directory = "/",
                            Name = "project.csproj",
                            Content = """
                                <Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
                                  <Import Project="$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props" Condition="Exists('$(MSBuildExtensionsPath)\$(MSBuildToolsVersion)\Microsoft.Common.props')" />
                                  <PropertyGroup>
                                    <OutputType>Library</OutputType>
                                    <TargetFrameworkVersion>v4.5</TargetFrameworkVersion>
                                  </PropertyGroup>
                                  <ItemGroup>
                                    <PackageReference Include="Some.Package" Version="2.0.0" />
                                  </ItemGroup>
                                  <Import Project="$(MSBuildToolsPath)\Microsoft.CSharp.targets" />
                                </Project>
                                """
                        },
                    ],
                    BaseCommitSha = "TEST-COMMIT-SHA",
                    CommitMessage = TestPullRequestCommitMessage,
                    PrTitle = TestPullRequestTitle,
                    PrBody = TestPullRequestBody,
                    DependencyGroup = null,
                },
                new MarkAsProcessed("TEST-COMMIT-SHA")
            ]
        );
    }

    [Fact]
    public async Task UpdatePackageWithDifferentVersionsInDifferentDirectories()
    {
        // this test passes `null` for discovery, analyze, and update workers to fully test the desired behavior

        // the same dependency Some.Package is reported for 3 cases:
        //   library1.csproj - top level dependency, already up to date
        //   library2.csproj - top level dependency, needs direct update
        //   library3.csproj - transitive dependency, needs pin
        await RunAsync(
            packages: [
                MockNuGetPackage.CreateSimplePackage("Some.Package", "1.0.0", "net8.0"),
                MockNuGetPackage.CreateSimplePackage("Some.Package", "2.0.0", "net8.0"),
                MockNuGetPackage.CreateSimplePackage("Package.With.Transitive.Dependency", "0.1.0", "net8.0", [(null, [("Some.Package", "1.0.0")])]),
            ],
            job: new Job()
            {
                AllowedUpdates = [new() { UpdateType = UpdateType.Security }],
                Dependencies = [
                    "Some.Package"
                ],
                SecurityAdvisories =
                [
                    new()
                    {
                        DependencyName = "Some.Package",
                        AffectedVersions = [Requirement.Parse("= 1.0.0")]
                    }
                ],
                SecurityUpdatesOnly = true,
                Source = new()
                {
                    Provider = "github",
                    Repo = "test/repo",
                    Directory = "/"
                }
            },
            files: [
                ("dirs.proj", """
                    <Project>
                      <ItemGroup>
                        <ProjectFile Include="library1\library1.csproj" />
                        <ProjectFile Include="library2\library2.csproj" />
                        <ProjectFile Include="library3\library3.csproj" />
                      </ItemGroup>
                    </Project>
                    """),
                ("Directory.Build.props", "<Project />"),
                ("Directory.Build.targets", "<Project />"),
                ("Directory.Packages.props", """
                    <Project>
                      <PropertyGroup>
                        <ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally>
                      </PropertyGroup>
                    </Project>
                    """),
                ("library1/library1.csproj", """
                    <Project Sdk="Microsoft.NET.Sdk">
                      <PropertyGroup>
                        <TargetFramework>net8.0</TargetFramework>
                      </PropertyGroup>
                      <ItemGroup>
                        <PackageReference Include="Some.Package" Version="2.0.0" />
                      </ItemGroup>
                    </Project>
                    """),
                ("library2/library2.csproj", """
                    <Project Sdk="Microsoft.NET.Sdk">
                      <PropertyGroup>
                        <TargetFramework>net8.0</TargetFramework>
                      </PropertyGroup>
                      <ItemGroup>
                        <PackageReference Include="Some.Package" Version="1.0.0" />
                      </ItemGroup>
                    </Project>
                    """),
                ("library3/library3.csproj", """
                    <Project Sdk="Microsoft.NET.Sdk">
                      <PropertyGroup>
                        <TargetFramework>net8.0</TargetFramework>
                      </PropertyGroup>
                      <ItemGroup>
                        <PackageReference Include="Package.With.Transitive.Dependency" Version="0.1.0" />
                      </ItemGroup>
                    </Project>
                    """),
            ],
            discoveryWorker: null,
            analyzeWorker: null,
            updaterWorker: null,
            expectedApiMessages: [
                new UpdatedDependencyList()
                {
                    Dependencies = [
                        new()
                        {
                            Name = "Some.Package",
                            Version = "2.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "2.0.0",
                                    File = "/library1/library1.csproj",
                                    Groups = ["dependencies"],
                                }
                            ]
                        },
                        new()
                        {
                            Name = "Some.Package",
                            Version = "1.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "1.0.0",
                                    File = "/library2/library2.csproj",
                                    Groups = ["dependencies"],
                                }
                            ]
                        },
                        new()
                        {
                            Name = "Package.With.Transitive.Dependency",
                            Version = "0.1.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "0.1.0",
                                    File = "/library3/library3.csproj",
                                    Groups = ["dependencies"],
                                }
                            ]
                        },
                        new()
                        {
                            Name = "Some.Package",
                            Version = "1.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "1.0.0",
                                    File = "/library3/library3.csproj",
                                    Groups = ["dependencies"],
                                }
                            ]
                        },
                    ],
                    DependencyFiles = [
                        "/Directory.Build.props",
                        "/Directory.Build.targets",
                        "/Directory.Packages.props",
                        "/library1/library1.csproj",
                        "/library2/library2.csproj",
                        "/library3/library3.csproj",
                    ],
                },
                new IncrementMetric()
                {
                    Metric = "updater.started",
                    Tags = new()
                    {
                        ["operation"] = "create_security_pr"
                    }
                },
                new CreatePullRequest()
                {
                    Dependencies = [
                        new()
                        {
                            Name = "Some.Package",
                            Version = "2.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "2.0.0",
                                    File = "/library2/library2.csproj",
                                    Groups = ["dependencies"],
                                    Source = new()
                                    {
                                        SourceUrl = null,
                                        Type = "nuget_repo",
                                    }
                                }
                            ],
                            PreviousVersion = "1.0.0",
                            PreviousRequirements = [
                                new()
                                {
                                    Requirement = "1.0.0",
                                    File = "/library2/library2.csproj",
                                    Groups = ["dependencies"],
                                }
                            ],
                        },
                        new()
                        {
                            Name = "Some.Package",
                            Version = "2.0.0",
                            Requirements = [
                                new()
                                {
                                    Requirement = "2.0.0",
                                    File = "/library3/library3.csproj",
                                    Groups = ["dependencies"],
                                    Source = new()
                                    {
                                        SourceUrl = null,
                                        Type = "nuget_repo",
                                    }
                                }
                            ],
                            PreviousVersion = "1.0.0",
                            PreviousRequirements = [
                                new()
                                {
                                    Requirement = "1.0.0",
                                    File = "/library3/library3.csproj",
                                    Groups = ["dependencies"],
                                }
                            ],
                        },
                    ],
                    UpdatedDependencyFiles = [
                        new()
                        {
                            Directory = "/library2",
                            Name = "library2.csproj",
                            Content = """
                                <Project Sdk="Microsoft.NET.Sdk">
                                  <PropertyGroup>
                                    <TargetFramework>net8.0</TargetFramework>
                                  </PropertyGroup>
                                  <ItemGroup>
                                    <PackageReference Include="Some.Package" Version="2.0.0" />
                                  </ItemGroup>
                                </Project>
                                """
                        },
                        new()
                        {
                            Directory = "/library3",
                            Name = "library3.csproj",
                            Content = """
                                <Project Sdk="Microsoft.NET.Sdk">
                                  <PropertyGroup>
                                    <TargetFramework>net8.0</TargetFramework>
                                  </PropertyGroup>
                                  <ItemGroup>
                                    <PackageReference Include="Package.With.Transitive.Dependency" Version="0.1.0" />
                                    <PackageReference Include="Some.Package" Version="2.0.0" />
                                  </ItemGroup>
                                </Project>
                                """
                        }
                    ],
                    BaseCommitSha = "TEST-COMMIT-SHA",
                    CommitMessage = TestPullRequestCommitMessage,
                    PrTitle = TestPullRequestTitle,
                    PrBody = TestPullRequestBody,
                    DependencyGroup = null,
                },
                new MarkAsProcessed("TEST-COMMIT-SHA")
            ]
        );
    }

    public const string TestPullRequestCommitMessage = "test-pull-request-commit-message";
    public const string TestPullRequestTitle = "test-pull-request-title";
    public const string TestPullRequestBody = "test-pull-request-body";

    internal static Task RunAsync(Job job, TestFile[] files, IDiscoveryWorker? discoveryWorker, IAnalyzeWorker? analyzeWorker, IUpdaterWorker? updaterWorker, object[] expectedApiMessages, MockNuGetPackage[]? packages = null, ExperimentsManager? experimentsManager = null, string? repoContentsPath = null)
    {
        var rawTestFiles = files.Select(f => (f.Path, Encoding.UTF8.GetBytes(f.Content))).ToArray();
        return RunAsync(job, rawTestFiles, discoveryWorker, analyzeWorker, updaterWorker, expectedApiMessages, packages, experimentsManager, repoContentsPath);
    }

    private static async Task RunAsync(Job job, RawTestFile[] rawFiles, IDiscoveryWorker? discoveryWorker, IAnalyzeWorker? analyzeWorker, IUpdaterWorker? updaterWorker, object[] expectedApiMessages, MockNuGetPackage[]? packages = null, ExperimentsManager? experimentsManager = null, string? repoContentsPath = null)
    {
        // arrange
        using var tempDirectory = new TemporaryDirectory();
        repoContentsPath ??= tempDirectory.DirectoryPath;
        await UpdateWorkerTestBase.MockNuGetPackagesInDirectory(packages, repoContentsPath);
        foreach (var (path, content) in rawFiles)
        {
            var fullPath = Path.Combine(repoContentsPath, path);
            var directory = Path.GetDirectoryName(fullPath)!;
            Directory.CreateDirectory(directory);
            await File.WriteAllBytesAsync(fullPath, content);
        }

        // act
        experimentsManager ??= new ExperimentsManager();
        var testApiHandler = new TestApiHandler();
        var logger = new TestLogger();
        var jobId = "TEST-JOB-ID";
        discoveryWorker ??= new DiscoveryWorker(jobId, experimentsManager, logger);
        analyzeWorker ??= new AnalyzeWorker(jobId, experimentsManager, logger);
        updaterWorker ??= new UpdaterWorker(jobId, experimentsManager, logger);

        var worker = new RunWorker(jobId, testApiHandler, discoveryWorker, analyzeWorker, updaterWorker, logger);
        var repoContentsPathDirectoryInfo = new DirectoryInfo(repoContentsPath);
        await worker.RunAsync(job, repoContentsPathDirectoryInfo, repoContentsPathDirectoryInfo, "TEST-COMMIT-SHA", experimentsManager);
        var actualApiMessages = testApiHandler.ReceivedMessages
            .Select(m =>
            {
                object newObject;
                switch (m.Object)
                {
                    // this isn't the place to verify the generated text
                    case CreatePullRequest create:
                        newObject = create with { CommitMessage = TestPullRequestCommitMessage, PrTitle = TestPullRequestTitle, PrBody = TestPullRequestBody };
                        break;
                    case UpdatePullRequest update:
                        newObject = update with { CommitMessage = TestPullRequestCommitMessage, PrTitle = TestPullRequestTitle, PrBody = TestPullRequestBody };
                        break;
                    // don't test callstacks
                    case UnknownError unknown:
                        var message = (string)unknown.Details["error-message"];
                        var stackTraceOffset = message.IndexOf('\n');
                        if (stackTraceOffset >= 0)
                        {
                            var messageWithoutStackTrace = message[..stackTraceOffset].TrimEnd('\r');
                            unknown.Details["error-message"] = messageWithoutStackTrace;
                        }

                        newObject = unknown;
                        break;
                    default:
                        newObject = m.Object;
                        break;
                }

                return (m.Type, Object: newObject);
            }
            ).ToArray();

        // assert
        for (int i = 0; i < Math.Min(actualApiMessages.Length, expectedApiMessages.Length); i++)
        {
            var actualMessage = actualApiMessages[i];
            var expectedMessage = expectedApiMessages[i];
            Assert.Equal(expectedMessage.GetType(), actualMessage.Type);

            var expectedContent = SerializeObjectAndType(expectedMessage);
            var actualContent = SerializeObjectAndType(actualMessage.Object);
            Assert.Equal(expectedContent, actualContent);
        }

        if (actualApiMessages.Length > expectedApiMessages.Length)
        {
            var extraApiMessages = actualApiMessages.Skip(expectedApiMessages.Length).Select(m => SerializeObjectAndType(m.Object)).ToArray();
            Assert.Fail($"Expected {expectedApiMessages.Length} API messages, but got {extraApiMessages.Length} extra:\n\t{string.Join("\n\t", extraApiMessages)}");
        }
        if (expectedApiMessages.Length > actualApiMessages.Length)
        {
            var missingApiMessages = expectedApiMessages.Skip(actualApiMessages.Length).Select(m => SerializeObjectAndType(m)).ToArray();
            Assert.Fail($"Expected {expectedApiMessages.Length} API messages, but only got {actualApiMessages.Length}; missing:\n\t{string.Join("\n\t", missingApiMessages)}");
        }
    }

    internal static string SerializeObjectAndType(object obj)
    {
        return $"{obj.GetType().Name}:{JsonSerializer.Serialize(obj, RunWorker.SerializerOptions)}";
    }
}
