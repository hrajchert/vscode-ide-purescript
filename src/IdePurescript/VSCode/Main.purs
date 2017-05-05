module IdePurescript.VSCode.Main where

import Prelude
import IdePurescript.VSCode.Config as Config
import PscIde.Command as Command
import VSCode.Notifications as Notify
import Control.Monad.Aff (Aff, attempt, delay, runAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (log, warn, error, info)
import Control.Monad.Eff.Ref (REF, Ref, readRef, newRef, writeRef)
import Control.Monad.Eff.Uncurried (EffFn4, EffFn3, EffFn2, EffFn1, runEffFn4, mkEffFn3, mkEffFn2, mkEffFn1)
import Control.Monad.Except (runExcept)
import Control.Promise (Promise, fromAff)
import Data.Array (filter, notElem, uncons)
import Data.Either (Either(..), either)
import Data.Foreign (Foreign, readInt)
import Data.Maybe (Maybe(Just, Nothing), fromMaybe, maybe)
import Data.Nullable (toNullable, Nullable)
import Data.String (trim, null)
import Data.String.Regex (Regex, regex, split)
import Data.String.Regex.Flags (noFlags)
import Data.Time.Duration (Milliseconds(..))
import IdePurescript.Build (Command(Command), build, rebuild)
import IdePurescript.Modules (ImportResult(FailedImport, AmbiguousImport, UpdatedImports), State, addExplicitImport, getModulesForFile, getQualModule, getUnqualActiveModules, initialModulesState)
import IdePurescript.PscErrors (PscError(PscError))
import IdePurescript.PscIde (getType)
import IdePurescript.PscIdeServer (Notify, ErrorLevel(Error, Warning, Info, Success))
import IdePurescript.PscIdeServer (startServer', QuitCallback, ServerEff) as P
import IdePurescript.Tokens (identifierAtPoint)
import IdePurescript.VSCode.Assist (addClause, caseSplit)
import IdePurescript.VSCode.Editor (GetText)
import IdePurescript.VSCode.Imports (addModuleImportCmd, addIdentImport)
import IdePurescript.VSCode.Pursuit (searchPursuit)
import IdePurescript.VSCode.Types (MainEff)
import PscIde (load) as P
import Unsafe.Coerce (unsafeCoerce)
import VSCode.Command (register)
import VSCode.Diagnostic (Diagnostic, mkDiagnostic)
import VSCode.Location (Location)
import VSCode.Notifications (appendOutputLine, createOutputChannel)
import VSCode.Position (mkPosition)
import VSCode.Range (mkRange, Range)
import VSCode.TextDocument (TextDocument, getPath, getText)
import VSCode.TextEditor (setTextViaDiff, getDocument)
import VSCode.Window (getActiveTextEditor, setStatusBarMessage, WINDOW)
import VSCode.Workspace (WORKSPACE, rootPath)

useEditor :: forall eff.  Notify (MainEff eff) -> Int -> (Ref State) -> String -> String -> Eff (MainEff eff) Unit
useEditor logError port modulesStateRef path text = do
  void $ runAff (logError Info <<< show) (const $ pure unit) $ do
    state <- getModulesForFile port path text
    liftEff $ writeRef modulesStateRef state

startServer' :: forall eff eff'. String -> String -> Int -> String -> Notify (P.ServerEff (workspace :: WORKSPACE | eff)) -> Notify (P.ServerEff (workspace :: WORKSPACE | eff)) -> Aff (P.ServerEff (workspace :: WORKSPACE | eff)) { port:: Maybe Int, quit:: P.QuitCallback eff' }
startServer' server purs _port root cb logCb = do
  useNpmPath <- liftEff Config.addNpmPath
  usePurs <- liftEff Config.usePurs
  packagePath <- liftEff Config.packagePath
  P.startServer' root (if usePurs then purs else server) useNpmPath usePurs ["src/**/*.purs", packagePath <> "/**/*.purs"] cb logCb

toDiagnostic :: Boolean -> PscError -> FileDiagnostic
toDiagnostic isError (PscError { message, filename, position, suggestion }) =
  { filename: fromMaybe "" filename
  , diagnostic: mkDiagnostic (range position) message (if isError then 0 else 1)
  , quickfix: conv suggestion
  }
  where
  range (Just { startLine, startColumn, endLine, endColumn}) =
    mkRange
      (mkPosition (startLine-1) (startColumn-1))
      (mkPosition (endLine-1) (endColumn-1))
  range _ = mkRange (mkPosition 0 0) (mkPosition 0 0)

  conv (Just { replacement, replaceRange }) = { suggest: true, replacement, range: range replaceRange }
  conv _ = { suggest: false, replacement: "", range: range Nothing }

type FileDiagnostic =
  { filename :: String
  , diagnostic :: Diagnostic
  , quickfix :: { suggest :: Boolean, replacement :: String, range :: Range }
  }
type VSBuildResult =
  { success :: Boolean
  , diagnostics :: Array FileDiagnostic
  , quickBuild :: Boolean
  , file :: String
  }

data Status = Building | BuildFailure | BuildErrors | BuildSuccess

showStatus :: forall eff. Status -> Eff (window :: WINDOW | eff) Unit
showStatus status = do
  let icon = case status of
              Building -> "$(beaker)"
              BuildFailure -> "$(bug)"
              BuildErrors -> "$(check)"
              BuildSuccess -> "$(check)"
  setStatusBarMessage $ icon <> " PureScript"

toDiagnostic' :: ErrorResult -> Array FileDiagnostic
toDiagnostic' { warnings, errors } = map (toDiagnostic true) errors <> map (toDiagnostic false) warnings

type ErrorResult = { warnings :: Array PscError, errors :: Array PscError } 

censorWarnings :: forall eff. ErrorResult -> Eff (MainEff eff) ErrorResult
censorWarnings { warnings, errors } = do
  codes <- Config.censorCodes
  let getCode (PscError { errorCode }) = errorCode
  pure $ { warnings: filter (flip notElem codes <<< getCode) warnings, errors }

emptyBuildResult :: forall t280.
  { success :: Boolean
  , diagnostics :: Array t280
  , quickBuild :: Boolean
  , file :: String
  }
emptyBuildResult = { success: false, diagnostics: [], quickBuild: false, file: "" } 

build' :: forall eff. Notify (MainEff eff) -> Notify (MainEff eff) -> String -> String -> Eff (MainEff eff) (Promise VSBuildResult)
build' notify logCb command directory = fromAff $ do
  liftEff $ logCb Info "Building"
  let buildCommand = either (const []) (\reg -> (split reg <<< trim) command) (regex "\\s+" noFlags)
  case uncons buildCommand of
    Just { head: cmd, tail: args } -> do
      liftEff $ logCb Info $ "Parsed build command, base command is: " <> cmd 
      liftEff $ showStatus Building
      useNpmDir <- liftEff $ Config.addNpmPath
      res <- build { command: Command cmd args, directory, useNpmDir }
      errors <- liftEff $ censorWarnings res.errors
      liftEff $ if res.success then showStatus BuildSuccess
                else showStatus BuildErrors
      pure $ { success: true, diagnostics: toDiagnostic' errors, quickBuild: false, file: "" }
    Nothing -> do
      liftEff $ notify Error "Error parsing PureScript build command"
      liftEff $ showStatus BuildFailure
      pure { success: false, diagnostics: [], quickBuild: false, file: "" }

addCompletionImport :: forall eff.  Notify (MainEff eff) -> (Ref State) -> Int -> Array Foreign -> Aff (MainEff eff) Unit
addCompletionImport logCb stateRef port args = case args of
  [ line, char, item ] -> case runExcept $ readInt line, runExcept $ readInt char of
    Right line', Right char' -> do
      let item' = (unsafeCoerce item) :: Command.TypeInfo
      Command.TypeInfo { identifier, module' } <- pure item'
      ed <- liftEff $ getActiveTextEditor
      case ed of
        Just ed' -> do
          let doc = getDocument ed'
          text <- liftEff $ getText doc
          path <- liftEff $ getPath doc
          state <- liftEff $ readRef stateRef
          { state: newState, result: output} <- addExplicitImport state port path text (Just module') identifier
          liftEff $ writeRef stateRef newState
          case output of
            UpdatedImports out -> void $ setTextViaDiff ed' out
            AmbiguousImport opts -> liftEff $ logCb Warning "Found ambiguous imports"
            FailedImport -> liftEff $ logCb Error "Failed to import"
          pure unit
        Nothing -> pure unit
      pure unit
    _, _ -> liftEff $ logCb Error "Wrong argument type"
  _ -> liftEff $ logCb Error "Wrong command arguments"


main :: forall eff. Eff (MainEff eff)
  { activate :: Eff (MainEff eff) (Promise Unit)
  , deactivate :: Eff (MainEff eff) Unit
  -- , build :: EffFn2 (MainEff eff) String String (Promise VSBuildResult)
  -- , updateFile :: EffFn2 (MainEff eff) String String Unit
  }
main = do
  -- modulesState <- newRef (initialModulesState)
  -- deactivateRef <- newRef (pure unit :: Eff (MainEff eff) Unit)
  -- portRef <- newRef Nothing
  output <- createOutputChannel "PureScript"

  let cmd s f = register ("purescript." <> s) (\_ -> f)
      cmdWithArgs s f = register ("purescript." <> s) f

  let deactivate :: Eff (MainEff eff) Unit
      deactivate =pure unit
      -- do
      --   join (readRef deactivateRef)
      --   writeRef deactivateRef (pure unit)
      --   writeRef portRef Nothing

  let logError :: Notify (MainEff eff)
      logError level str = do
        appendOutputLine output str
        case level of
          Success -> log str
          Info -> info str
          Warning -> warn str
          Error -> error str
  let showError :: Notify (MainEff eff)
      showError level str = do
        appendOutputLine output str
        logError level str
        case level of
          Success -> Notify.showInfo str
          Info -> Notify.showInfo str
          Warning -> Notify.showWarning str
          Error -> Notify.showError str                 
      

  -- let startPscIdeServer =
  --       do
  --         server <- liftEff Config.serverExe
  --         purs <- liftEff Config.pursExe
  --         port' <- liftEff Config.pscIdePort
  --         rootPath <- liftEff rootPath
  --         -- TODO pass in port just when explicitly defined
  --         startRes <- startServer' server purs port' rootPath showError logError
  --         retry 6 case startRes of
  --           { port: Just port, quit } -> do
  --             _<- P.load port [] []
  --             liftEff do
  --               writeRef deactivateRef quit
  --               writeRef portRef $ Just port
  --           _ -> pure unit
  --       where
  --         retry :: Int -> Aff (MainEff eff) Unit -> Aff (MainEff eff) Unit
  --         retry n a | n > 0 = do
  --           res <- attempt a
  --           case res of
  --             Right r -> pure r
  --             Left err -> do
  --               liftEff $ logError Info $ "Retrying starting server after 500ms: " <> show err
  --               delay (Milliseconds 500.0)
  --               retry (n - 1) a
  --         retry _ a = a

  --     start :: Eff (MainEff eff) Unit
  --     start = void $ runAff (logError Error <<< show) (const $ pure unit) $ startPscIdeServer

  --     restart :: Eff (MainEff eff) Unit
  --     restart = do
  --       deactivate
  --       start

  -- let withPortDef :: forall eff' a. Eff (ref :: REF | eff') a -> (Int -> Eff (ref :: REF | eff') a) -> Eff (ref :: REF | eff') a
  --     withPortDef def f = readRef portRef >>= maybe def f
  -- let withPort :: forall eff'. (Int -> Eff (ref :: REF | eff') Unit) -> Eff (ref :: REF | eff') Unit
  --     withPort = withPortDef (pure unit)
  
  let initialise = fromAff $ do
        -- auto <- liftEff $ Config.autoStartPscIde
        -- when auto startPscIdeServer
        liftEff do
          -- cmd "addImport" $ withPort $ addModuleImportCmd modulesState
          cmd "addExplicitImport" $ addIdentImport
          cmd "caseSplit" $ caseSplit
          cmd "addClause" $ addClause
          -- cmd "restartPscIde" restart
          -- cmd "startPscIde" start
          -- cmd "stopPscIde" deactivate
          -- cmd "searchPursuit" $ withPort searchPursuit
          -- cmdWithArgs "addCompletionImport" $ \args -> withPort \port -> do
          --   autocompleteAddImport <- Config.autocompleteAddImport
          --   when autocompleteAddImport $
          --     void $ runAff (logError Info <<< show) (const $ pure unit) $ addCompletionImport logError modulesState port args

  pure $ {
      activate: initialise
    , deactivate: deactivate
    -- , build: mkEffFn2 $ build' showError logError
    -- , updateFile: mkEffFn2 $ \fname text -> withPort \port -> useEditor logError port modulesState fname text
    }
