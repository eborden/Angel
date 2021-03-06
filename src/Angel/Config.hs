{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
module Angel.Config ( monitorConfig
                    , modifyProg
                    , expandByCount ) where

import Control.Exception ( try
                         , SomeException )
import qualified Data.Map as M
import Control.Monad ( when
                     , (>=>) )
import Control.Concurrent.STM ( STM
                              , TVar
                              , writeTVar
                              , readTVar
                              , atomically )
import Data.Configurator ( load
                         , getMap
                         , Worth(Required) )
import Data.Configurator.Types ( Value(Number, String)
                               , Name )
import qualified Data.Traversable as T
import qualified Data.HashMap.Lazy as HM
import Data.Maybe ( isNothing
                  , isJust )
import Data.Monoid ( (<>) )
import qualified Data.Text as T
import Angel.Job ( syncSupervisors )
import Angel.Data ( Program( exec
                           , delay
                           , stdout
                           , stderr
                           , logExec
                           , pidFile
                           , workingDir
                           , name
                           , env )
                  , SpecKey
                  , GroupConfig(..)
                  , defaultProgram )
import Angel.Log ( logger )
import Angel.Util ( waitForWake
                  , nnull
                  , expandPath )

void :: Monad m => m a -> m ()
void m = m >> return ()

-- |produce a mapping of name -> program for every program
buildConfigMap :: HM.HashMap Name Value -> IO SpecKey
buildConfigMap cfg = do
    return $! HM.foldlWithKey' addToMap M.empty cfg
  where
    addToMap :: SpecKey -> Name -> Value -> SpecKey
    addToMap m name value
      | nnull basekey && nnull localkey = 
        let !newprog = case M.lookup basekey m of
                          Just prog -> modifyProg prog localkey value
                          Nothing   -> modifyProg defaultProgram {name = basekey, env = []} localkey value
            in
        M.insert basekey newprog m
      | otherwise = m
      where (basekey, '.':localkey) = break (== '.') $ T.unpack name

checkConfigValues :: SpecKey -> IO SpecKey
checkConfigValues progs = (mapM_ checkProgram $ M.elems progs) >> (return progs)
  where
    checkProgram p = do
        when (isNothing $ exec p) $ error $ name p ++ " does not have an 'exec' specification"
        when ((isJust $ logExec p) &&
            (isJust (stdout p) || isJust (stderr p) )) $ error $ name p ++ " cannot have both a logger process and stderr/stdout"

modifyProg :: Program -> String -> Value -> Program
modifyProg prog "exec" (String s) = prog{exec = Just (T.unpack s)}
modifyProg prog "exec" _ = error "wrong type for field 'exec'; string required"

modifyProg prog "delay" (Number n) | n < 0     = error "delay value must be >= 0"
                                   | otherwise = prog{delay = Just $ round n}
modifyProg prog "delay" _ = error "wrong type for field 'delay'; integer"

modifyProg prog "stdout" (String s) = prog{stdout = Just (T.unpack s)}
modifyProg prog "stdout" _ = error "wrong type for field 'stdout'; string required"

modifyProg prog "stderr" (String s) = prog{stderr = Just (T.unpack s)}
modifyProg prog "stderr" _ = error "wrong type for field 'stderr'; string required"

modifyProg prog "directory" (String s) = prog{workingDir = (Just $ T.unpack s)}
modifyProg prog "directory" _ = error "wrong type for field 'directory'; string required"

modifyProg prog "logger" (String s) = prog{logExec = (Just $ T.unpack s)}
modifyProg prog "logger" _ = error "wrong type for field 'logger'; string required"

modifyProg prog "pidfile" (String s) = prog{pidFile = (Just $ T.unpack s)}
modifyProg prog "pidfile" _ = error "wrong type for field 'pidfile'; string required"

modifyProg prog ('e':'n':'v':'.':envVar) (String s) = prog{env = envVar'}
  where envVar' = (envVar, T.unpack s):(env prog)
modifyProg prog ('e':'n':'v':'.':_) _ = error "wrong type for env field; string required"

modifyProg prog n _ = prog


-- |invoke the parser to process the file at configPath
-- |produce a SpecKey
processConfig :: String -> IO (Either String SpecKey)
processConfig configPath = do 
    mconf <- try $ process =<< load [Required configPath]

    case mconf of
        Right config -> return $ Right config
        Left (e :: SomeException) -> return $ Left $ show e
  where process = getMap                 >=>
                  return . expandByCount >=>
                  buildConfigMap         >=>
                  expandPaths            >=>
                  checkConfigValues

-- |preprocess config into multiple programs if "count" is specified
expandByCount :: HM.HashMap Name Value -> HM.HashMap Name Value
expandByCount cfg = HM.unions expanded
  where expanded :: [HM.HashMap Name Value]
        expanded         = concat $ HM.foldlWithKey' expand' [] groupedByProgram
        expand'  :: [[HM.HashMap Name Value]] -> Name -> HM.HashMap Name Value -> [[HM.HashMap Name Value]]
        expand' acc      = fmap (:acc) . expand
        groupedByProgram :: HM.HashMap Name (HM.HashMap Name Value)
        groupedByProgram = HM.foldlWithKey' binByProg HM.empty cfg
        binByProg h fullKey v
          | prog /= "" && localKey /= "" = HM.insertWith HM.union prog (HM.singleton localKey v) h
          | otherwise                    = h
          where (prog, localKeyWithLeadingDot) = T.breakOn "." fullKey
                localKey                 = T.drop 1 localKeyWithLeadingDot
        expand :: Name -> HM.HashMap Name Value -> [HM.HashMap Name Value]
        expand prog pcfg = maybe [reflatten prog pcfg]
                                 expandWithCount
                                 (HM.lookup "count" pcfg)
          where expandWithCount (Number n)
                  | n >= 0    = [ reflatten (genProgName i) (rewriteConfig i pcfg) | i <- [1..n] ]
                  | otherwise = error "count must be >= 0"
                expandWithCount _ = error "count must be a number or not specified"
                genProgName i     = prog <> "-" <> textNumber i

rewriteConfig :: Rational -> HM.HashMap Name Value -> HM.HashMap Name Value
rewriteConfig n = HM.insert "env.ANGEL_PROCESS_NUMBER" procNumber . HM.adjust rewritePidfile "pidfile"
  where procNumber                   = String n'
        n'                           = textNumber n
        rewritePidfile (String path) = String $ rewrittenFilename <> extension
          where rewrittenFilename     = filename <> "-" <> n'
                (filename, extension) = T.breakOn "." path
        rewritePidfile x              = x

textNumber :: Rational -> T.Text
textNumber = T.pack . show . truncate

reflatten :: Name -> HM.HashMap Name Value -> HM.HashMap Name Value
reflatten prog pcfg = HM.fromList asList
  where asList            = map prependKey $ filter notCount $ HM.toList pcfg
        prependKey (k, v) = ((prog <> "." <> k), v)
        notCount          = not . (== "count") . fst

-- |given a new SpecKey just parsed from the file, update the 
-- |shared state TVar
updateSpecConfig :: TVar GroupConfig -> SpecKey -> STM ()
updateSpecConfig sharedGroupConfig spec = do 
    cfg <- readTVar sharedGroupConfig
    writeTVar sharedGroupConfig cfg{spec=spec}

-- |read the config file, update shared state with current spec, 
-- |re-sync running supervisors, wait for the HUP TVar, then repeat!
monitorConfig :: String -> TVar GroupConfig -> TVar (Maybe Int) -> IO ()
monitorConfig configPath sharedGroupConfig wakeSig = do 
    let log = logger "config-monitor"
    mspec <- processConfig configPath
    case mspec of 
        Left e     -> do 
            log $ " <<<< Config Error >>>>\n" ++ e
            log " <<<< Config Error: Skipping reload >>>>"
        Right spec -> do 
            atomically $ updateSpecConfig sharedGroupConfig spec
            syncSupervisors sharedGroupConfig
    waitForWake wakeSig
    log "HUP caught, reloading config"

expandPaths :: SpecKey -> IO SpecKey
expandPaths = T.mapM expandProgramPaths

expandProgramPaths :: Program -> IO Program
expandProgramPaths prog = do exec'       <- maybeExpand $ exec prog
                             stdout'     <- maybeExpand $ stdout prog
                             stderr'     <- maybeExpand $ stderr prog
                             workingDir' <- maybeExpand $ workingDir prog
                             pidFile'    <- maybeExpand $ pidFile prog
                             return prog { exec       = exec',
                                           stdout     = stdout',
                                           stderr     = stderr',
                                           workingDir = workingDir',
                                           pidFile    = pidFile' }
    where maybeExpand = T.traverse expandPath
