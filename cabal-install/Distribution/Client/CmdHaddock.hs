{-# LANGUAGE NamedFieldPuns #-}

-- | cabal-install CLI command: haddock
--
module Distribution.Client.CmdHaddock (
    -- * The @haddock@ CLI and action
    haddockCommand,
    haddockAction,

    -- * Internals exposed for testing
    TargetProblem(..),
    selectPackageTargets,
    selectComponentTarget
  ) where

import Distribution.Client.ProjectOrchestration
import Distribution.Client.CmdErrorMessages

import Distribution.Client.Setup
         ( GlobalFlags, ConfigFlags(..), ConfigExFlags, InstallFlags )
import qualified Distribution.Client.Setup as Client
import Distribution.Simple.Setup
         ( HaddockFlags(..), TestFlags, fromFlagOrDefault )
import Distribution.Simple.Command
         ( CommandUI(..), usageAlternatives )
import Distribution.Verbosity
         ( Verbosity, normal )
import Distribution.Simple.Utils
         ( wrapText, die' )

import Control.Monad (when)


haddockCommand :: CommandUI (ConfigFlags, ConfigExFlags, InstallFlags
                            ,HaddockFlags, TestFlags)
haddockCommand = Client.installCommand {
  commandName         = "v2-haddock",
  commandSynopsis     = "Build Haddock documentation",
  commandUsage        = usageAlternatives "v2-haddock" [ "[FLAGS] TARGET" ],
  commandDescription  = Just $ \_ -> wrapText $
        "Build Haddock documentation for the specified packages within the "
     ++ "project.\n\n"

     ++ "Any package in the project can be specified. If no package is "
     ++ "specified, the default is to build the documentation for the package "
     ++ "in the current directory. The default behaviour is to build "
     ++ "documentation for the exposed modules of the library component (if "
     ++ "any). This can be changed with the '--internal', '--executables', "
     ++ "'--tests', '--benchmarks' or '--all' flags.\n\n"

     ++ "Currently, documentation for dependencies is NOT built. This "
     ++ "behavior may change in future.\n\n"

     ++ "Additional configuration flags can be specified on the command line "
     ++ "and these extend the project configuration from the 'cabal.project', "
     ++ "'cabal.project.local' and other files.",
  commandNotes        = Just $ \pname ->
        "Examples:\n"
     ++ "  " ++ pname ++ " v2-haddock pkgname"
     ++ "    Build documentation for the package named pkgname\n\n"

     ++ cmdCommonHelpTextNewBuildBeta
   }
   --TODO: [nice to have] support haddock on specific components, not just
   -- whole packages and the silly --executables etc modifiers.

-- | The @haddock@ command is TODO.
--
-- For more details on how this works, see the module
-- "Distribution.Client.ProjectOrchestration"
--
haddockAction :: (ConfigFlags, ConfigExFlags, InstallFlags, HaddockFlags, TestFlags)
                 -> [String] -> GlobalFlags -> IO ()
haddockAction (configFlags, configExFlags, installFlags, haddockFlags, testFlags)
                targetStrings globalFlags = do

    baseCtx <- establishProjectBaseContext verbosity cliConfig OtherCommand

    targetSelectors <- either (reportTargetSelectorProblems verbosity) return
                   =<< readTargetSelectors (localPackages baseCtx) Nothing targetStrings

    buildCtx <-
      runProjectPreBuildPhase verbosity baseCtx $ \elaboratedPlan -> do

            when (buildSettingOnlyDeps (buildSettings baseCtx)) $
              die' verbosity
                "The haddock command does not support '--only-dependencies'."

              -- When we interpret the targets on the command line, interpret them as
              -- haddock targets
            targets <- either (reportTargetProblems verbosity) return
                     $ resolveTargets
                         (selectPackageTargets haddockFlags)
                         selectComponentTarget
                         TargetProblemCommon
                         elaboratedPlan
                         Nothing
                         targetSelectors

            let elaboratedPlan' = pruneInstallPlanToTargets
                                    TargetActionHaddock
                                    targets
                                    elaboratedPlan
            return (elaboratedPlan', targets)

    printPlan verbosity baseCtx buildCtx

    buildOutcomes <- runProjectBuildPhase verbosity baseCtx buildCtx
    runProjectPostBuildPhase verbosity baseCtx buildCtx buildOutcomes
  where
    verbosity = fromFlagOrDefault normal (configVerbosity configFlags)
    cliConfig = commandLineFlagsToProjectConfig
                  globalFlags configFlags configExFlags
                  installFlags
                  mempty -- ClientInstallFlags, not needed here
                  haddockFlags testFlags

-- | This defines what a 'TargetSelector' means for the @haddock@ command.
-- It selects the 'AvailableTarget's that the 'TargetSelector' refers to,
-- or otherwise classifies the problem.
--
-- For the @haddock@ command we select all buildable libraries. Additionally,
-- depending on the @--executables@ flag we also select all the buildable exes.
-- We do similarly for test-suites, benchmarks and foreign libs.
--
selectPackageTargets  :: HaddockFlags -> TargetSelector
                      -> [AvailableTarget k] -> Either TargetProblem [k]
selectPackageTargets haddockFlags targetSelector targets

    -- If there are any buildable targets then we select those
  | not (null targetsBuildable)
  = Right targetsBuildable

    -- If there are targets but none are buildable then we report those
  | not (null targets)
  = Left (TargetProblemNoneEnabled targetSelector targets')

    -- If there are no targets at all then we report that
  | otherwise
  = Left (TargetProblemNoTargets targetSelector)
  where
    targets'         = forgetTargetsDetail    (map disableNotRequested targets)
    targetsBuildable = selectBuildableTargets (map disableNotRequested targets)

    -- When there's a target filter like "pkg:exes" then we do select exes,
    -- but if it's just a target like "pkg" then we don't build docs for exes
    -- unless they are requested by default (i.e. by using --executables)
    disableNotRequested t@(AvailableTarget _ cname (TargetBuildable _ _) _)
      | not (isRequested targetSelector (componentKind cname))
      = t { availableTargetStatus = TargetDisabledByUser }
    disableNotRequested t = t

    isRequested (TargetPackage _ _ (Just _)) _ = True
    isRequested (TargetAllPackages (Just _)) _ = True
    isRequested _ LibKind    = True
--  isRequested _ SubLibKind = True --TODO: what about sublibs?

    -- TODO/HACK, we encode some defaults here as v2-haddock's logic;
    -- make sure this matches the defaults applied in
    -- "Distribution.Client.ProjectPlanning"; this may need more work
    -- to be done properly
    --
    -- See also https://github.com/haskell/cabal/pull/4886
    isRequested _ FLibKind   = fromFlagOrDefault False (haddockForeignLibs haddockFlags)
    isRequested _ ExeKind    = fromFlagOrDefault False (haddockExecutables haddockFlags)
    isRequested _ TestKind   = fromFlagOrDefault False (haddockTestSuites  haddockFlags)
    isRequested _ BenchKind  = fromFlagOrDefault False (haddockBenchmarks  haddockFlags)


-- | For a 'TargetComponent' 'TargetSelector', check if the component can be
-- selected.
--
-- For the @haddock@ command we just need the basic checks on being buildable
-- etc.
--
selectComponentTarget :: SubComponentTarget
                      -> AvailableTarget k -> Either TargetProblem k
selectComponentTarget subtarget =
    either (Left . TargetProblemCommon) Right
  . selectComponentTargetBasic subtarget


-- | The various error conditions that can occur when matching a
-- 'TargetSelector' against 'AvailableTarget's for the @haddock@ command.
--
data TargetProblem =
     TargetProblemCommon       TargetProblemCommon

     -- | The 'TargetSelector' matches targets but none are buildable
   | TargetProblemNoneEnabled TargetSelector [AvailableTarget ()]

     -- | There are no targets at all
   | TargetProblemNoTargets   TargetSelector
  deriving (Eq, Show)

reportTargetProblems :: Verbosity -> [TargetProblem] -> IO a
reportTargetProblems verbosity =
    die' verbosity . unlines . map renderTargetProblem

renderTargetProblem :: TargetProblem -> String
renderTargetProblem (TargetProblemCommon problem) =
    renderTargetProblemCommon "build documentation for" problem

renderTargetProblem (TargetProblemNoneEnabled targetSelector targets) =
    renderTargetProblemNoneEnabled "build documentation for" targetSelector targets

renderTargetProblem(TargetProblemNoTargets targetSelector) =
    renderTargetProblemNoTargets "build documentation for" targetSelector
