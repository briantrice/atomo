{-# LANGUAGE BangPatterns #-}
module Atomo.Environment where

import Control.Monad.Cont
import Control.Monad.Error
import Control.Monad.State
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan
import Data.IORef
import Data.List (nub)
import Data.Maybe (isJust)
import System.Directory
import System.FilePath
import System.IO.Unsafe
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Language.Haskell.Interpreter as H
import qualified Text.PrettyPrint as P

import Atomo.Method
import Atomo.Parser
import Atomo.Pretty
import Atomo.Types
import {-# SOURCE #-} qualified Atomo.Kernel as Kernel


-----------------------------------------------------------------------------
-- Execution ----------------------------------------------------------------
-----------------------------------------------------------------------------

-- | execute an action in a new thread, initializing the environment and
-- printing a traceback on error
exec :: VM Value -> IO ()
exec x = execWith (initEnv >> x) startEnv

-- | execute an action in a new thread, printing a traceback on error
execWith :: VM Value -> Env -> IO ()
execWith x e = do
    haltChan <- newChan

    forkIO $ do
        runWith (go x >> gets halt >>= liftIO >> return (particle "ok")) e
            { halt = writeChan haltChan ()
            }

        return ()

    readChan haltChan

-- | execute x, printing an error if there is one
go :: VM Value -> VM Value
go x = catchError x (\e -> printError e >> return (particle "ok"))

-- | execute x, initializing the environment with initEnv
run :: VM Value -> IO (Either AtomoError Value)
run x = runWith (initEnv >> x) startEnv

-- | evaluate x with e as the environment
runWith :: VM Value -> Env -> IO (Either AtomoError Value)
runWith x e = evalStateT (runContT (runErrorT x) return) e

-- | print an error, including the previous 10 expressions evaluated
-- with the most recent on the bottom
printError :: AtomoError -> VM ()
printError err = do
    t <- traceback

    if not (null t)
        then do
            liftIO (putStrLn "traceback:")

            forM_ t $ \e -> liftIO $
                print (prettyStack e)

            liftIO (putStrLn "")
        else return ()

    prettyError err >>= liftIO . print

    modify $ \s -> s { stack = [] }
  where
    traceback = fmap (reverse . take 10 . reverse) (gets stack)

prettyError :: AtomoError -> VM P.Doc
prettyError (Error v) = fmap (P.text "error:" P.<+>) (prettyVM v)
prettyError e = return (pretty e)

-- | pretty-print by sending \@show to the object
prettyVM :: Value -> VM P.Doc
prettyVM = fmap (P.text . fromString) . dispatch . (single "show")

-- | spawn a process to execute x. returns the Process.
spawn :: VM Value -> VM Value
spawn x = do
    e <- get
    chan <- liftIO newChan
    tid <- liftIO . forkIO $ do
        runWith (go x >> return (particle "ok")) (e { channel = chan })
        return ()

    return (Process chan tid)

-- | set up the primitive objects, etc.
initEnv :: VM ()
{-# INLINE initEnv #-}
initEnv = do
    -- the very root object
    object <- newObject id

    -- top scope is a proto delegating to the root object
    topObj <- newObject $ \o -> o { oDelegates = [object] }
    modify $ \e -> e { top = topObj }

    -- define Object as the root object
    define (psingle "Object" PThis) (Primitive Nothing object)
    modify $ \e -> e
        { primitives = (primitives e) { idObject = rORef object }
        }

    -- this thread's channel
    chan <- liftIO newChan
    modify $ \e -> e { channel = chan }

    -- define primitive objects
    forM_ primObjs $ \(n, f) -> do
        o <- newObject $ \o -> o { oDelegates = [object] }
        define (psingle n PThis) (Primitive Nothing o)
        modify $ \e -> e { primitives = f (primitives e) (rORef o) }

    Kernel.load
  where
    primObjs =
        [ ("Block", \is r -> is { idBlock = r })
        , ("Char", \is r -> is { idChar = r })
        , ("Continuation", \is r -> is { idContinuation = r })
        , ("Double", \is r -> is { idDouble = r })
        , ("Expression", \is r -> is { idExpression = r })
        , ("Haskell", \is r -> is { idHaskell = r })
        , ("Integer", \is r -> is { idInteger = r })
        , ("List", \is r -> is { idList = r })
        , ("Message", \is r -> is { idMessage = r })
        , ("Method", \is r -> is { idMethod = r })
        , ("Particle", \is r -> is { idParticle = r })
        , ("Process", \is r -> is { idProcess = r })
        , ("Pattern", \is r -> is { idPattern = r })
        , ("String", \is r -> is { idString = r })
        ]



-----------------------------------------------------------------------------
-- General ------------------------------------------------------------------
-----------------------------------------------------------------------------

-- | evaluation
eval :: Expr -> VM Value
eval e = eval' e `catchError` pushStack
  where
    pushStack err = do
        modify $ \s -> s { stack = e : stack s }
        throwError err

    eval' (Define { ePattern = p, eExpr = ev }) = do
        define p ev
        return (particle "ok")
    eval' (Set { ePattern = p@(PSingle {}), eExpr = ev }) = do
        v <- eval ev
        define p (Primitive (eLocation ev) v)
        return v
    eval' (Set { ePattern = p@(PKeyword {}), eExpr = ev }) = do
        v <- eval ev
        define p (Primitive (eLocation ev) v)
        return v
    eval' (Set { ePattern = p, eExpr = ev }) = do
        v <- eval ev

        is <- gets primitives
        if match is p v
            then do
                forM_ (bindings' p v) $ \(p', v') -> do
                    define p' (Primitive (eLocation ev) v')

                return v
            else throwError (Mismatch p v)
    eval' (Dispatch
            { eMessage = ESingle
                { emID = i
                , emName = n
                , emTarget = t
                }
            }) = do
        v <- eval t
        dispatch (Single i n v)
    eval' (Dispatch
            { eMessage = EKeyword
                { emID = i
                , emNames = ns
                , emTargets = ts
                }
            }) = do
        vs <- mapM eval ts
        dispatch (Keyword i ns vs)
    eval' (Operator { eNames = ns, eAssoc = a, ePrec = p }) = do
        forM_ ns $ \n -> modify $ \s ->
            s { parserState = (n, (a, p)) : parserState s }

        return (particle "ok")
    eval' (Primitive { eValue = v }) = return v
    eval' (EBlock { eArguments = as, eContents = es }) = do
        t <- gets top
        return (Block t as es)
    eval' (EDispatchObject {}) = do
        c <- gets call
        newObject $ \o -> o
            { oMethods =
                ( toMethods
                    [ (psingle "sender" PThis, callSender c)
                    , (psingle "message" PThis, Message (callMessage c))
                    , (psingle "context" PThis, callContext c)
                    ]
                , emptyMap
                )
            }
    eval' (EList { eContents = es }) = do
        vs <- mapM eval es
        list vs
    eval' (EParticle { eParticle = EPMSingle n }) =
        return (Particle $ PMSingle n)
    eval' (EParticle { eParticle = EPMKeyword ns mes }) = do
        mvs <- forM mes $
            maybe (return Nothing) (fmap Just . eval)
        return (Particle $ PMKeyword ns mvs)
    eval' (ETop {}) = gets top
    eval' (EVM { eAction = x }) = x

-- | evaluating multiple expressions, returning the last result
evalAll :: [Expr] -> VM Value
evalAll [] = throwError NoExpressions
evalAll [e] = eval e
evalAll (e:es) = eval e >> evalAll es

-- | object creation
newObject :: (Object -> Object) -> VM Value
newObject f = fmap Reference . liftIO $
    newIORef . f $ Object
        { oDelegates = []
        , oMethods = noMethods
        }

-- | run x with t as its toplevel object
withTop :: Value -> VM Value -> VM Value
withTop t x = do
    o <- gets top
    modify (\e -> e { top = t })

    res <- catchError x $ \err -> do
        modify (\e -> e { top = o })
        throwError err

    modify (\e -> e { top = o })

    return res


-----------------------------------------------------------------------------
-- Define -------------------------------------------------------------------
-----------------------------------------------------------------------------

-- | define a pattern to evaluate an expression
define :: Pattern -> Expr -> VM ()
define !p !e = do
    is <- gets primitives
    newp <- methodPattern p

    os <-
        case p of
            PKeyword { ppTargets = (t:_) } | isTop t ->
                targets is (head (ppTargets newp))
            _ -> targets is newp

    m <- method newp e
    forM_ os $ \o -> do
        obj <- liftIO (readIORef o)

        let (oss, oks) = oMethods obj
            ms (PSingle {}) = (addMethod (m o) oss, oks)
            ms (PKeyword {}) = (oss, addMethod (m o) oks)
            ms x = error $ "impossible: defining with pattern " ++ show x

        liftIO . writeIORef o $
            obj { oMethods = ms newp }
  where
    isTop PThis = True
    isTop (PObject ETop {}) = True
    isTop _ = False

    method p' (Primitive _ v) = return (\o -> Slot (setSelf o p') v)
    method p' e' = gets top >>= \t ->
        return (\o -> Responder (setSelf o p') t e')

    methodPattern p'@(PSingle { ppTarget = t }) = do
        t' <- methodPattern t
        return p' { ppTarget = t' }
    methodPattern p'@(PKeyword { ppTargets = ts }) = do
        ts' <- mapM methodPattern ts
        return p' { ppTargets = ts' }
    methodPattern PThis = fmap PMatch (gets top)
    methodPattern (PObject oe) = fmap PMatch (eval oe)
    methodPattern (PNamed n p') = fmap (PNamed n) (methodPattern p')
    methodPattern p' = return p'

    -- | Swap out a reference match with PThis, for inserting on the object
    setSelf :: ORef -> Pattern -> Pattern
    setSelf o (PKeyword i ns ps) =
        PKeyword i ns (map (setSelf o) ps)
    setSelf o (PMatch (Reference x))
        | o == x = PThis
    setSelf o (PNamed n p') =
        PNamed n (setSelf o p')
    setSelf o (PSingle i n t) =
        PSingle i n (setSelf o t)
    setSelf _ p' = p'


-- | find the target objects for a pattern
targets :: IDs -> Pattern -> VM [ORef]
targets _ (PMatch v) = orefFor v >>= return . (: [])
targets is (PSingle _ _ p) = targets is p
targets is (PKeyword _ _ ps) = do
    ts <- mapM (targets is) ps
    return (nub (concat ts))
targets is (PNamed _ p) = targets is p
targets is PAny = return [idObject is]
targets is (PList _) = return [idList is]
targets is (PHeadTail h t) = do
    ht <- targets is h
    tt <- targets is t
    if idChar is `elem` ht || idString is `elem` tt
        then return [idList is, idString is]
        else return [idList is]
targets is (PPMKeyword {}) = return [idParticle is]
targets _ p = error $ "no targets for " ++ show p



-----------------------------------------------------------------------------
-- Dispatch -----------------------------------------------------------------
-----------------------------------------------------------------------------

-- | dispatch a message and return a value
dispatch :: Message -> VM Value
dispatch !m = do
    find <- findFirstMethod m vs
    case find of
        Just method -> runMethod method m
        Nothing ->
            case vs of
                [v] -> sendDNU v
                _ -> sendDNUs vs 0
  where
    vs =
        case m of
            Single { mTarget = t } -> [t]
            Keyword { mTargets = ts } -> ts

    sendDNU v = do
        find <- findMethod v (dnuSingle v)
        case find of
            Nothing -> throwError $ DidNotUnderstand m
            Just method -> runMethod method (dnuSingle v)

    sendDNUs [] _ = throwError $ DidNotUnderstand m
    sendDNUs (v:vs') n = do
        find <- findMethod v (dnu v n)
        case find of
            Nothing -> sendDNUs vs' (n + 1)
            Just method -> runMethod method (dnu v n)

    dnu v n = keyword
        ["did-not-understand", "at"]
        [v, Message m, Integer n]

    dnuSingle v = keyword
        ["did-not-understand"]
        [v, Message m]


-- | find a method on object `o' that responds to `m', searching its
-- delegates if necessary
findMethod :: Value -> Message -> VM (Maybe Method)
findMethod v m = do
    is <- gets primitives
    r <- orefFor v
    o <- liftIO (readIORef r)
    case relevant (is { idMatch = r }) o m of
        Nothing -> findFirstMethod m (oDelegates o)
        Just mt -> return (Just mt)

-- | find the first value that has a method defiend for `m'
findFirstMethod :: Message -> [Value] -> VM (Maybe Method)
findFirstMethod _ [] = return Nothing
findFirstMethod m (v:vs) = do
    findMethod v m
        >>= maybe (findFirstMethod m vs) (return . Just)

-- | find a relevant method for message `m' on object `o'
relevant :: IDs -> Object -> Message -> Maybe Method
relevant ids o m =
    lookupMap (mID m) (methods m) >>= firstMatch ids m
  where
    methods (Single {}) = fst (oMethods o)
    methods (Keyword {}) = snd (oMethods o)

    firstMatch _ _ [] = Nothing
    firstMatch ids' m' (mt:mts)
        | match ids' (mPattern mt) (Message m') = Just mt
        | otherwise = firstMatch ids' m' mts

-- | check if a value matches a given pattern
-- note that this is much faster when pure, so it uses unsafePerformIO
-- to check things like delegation matches.
match :: IDs -> Pattern -> Value -> Bool
{-# NOINLINE match #-}
match ids PThis (Reference y) =
    refMatch ids (idMatch ids) y
match ids PThis y =
    match ids (PMatch (Reference (idMatch ids))) (Reference (orefFrom ids y))
match ids (PMatch (Reference x)) (Reference y) =
    refMatch ids x y
match ids (PMatch (Reference x)) y =
    match ids (PMatch (Reference x)) (Reference (orefFrom ids y))
match _ (PMatch x) y =
    x == y
match ids
    (PSingle { ppTarget = p })
    (Message (Single { mTarget = t })) =
    match ids p t
match ids
    (PKeyword { ppTargets = ps })
    (Message (Keyword { mTargets = ts })) =
    matchAll ids ps ts
match ids (PNamed _ p) v = match ids p v
match _ PAny _ = True
match ids (PList ps) (List v) = matchAll ids ps vs
  where
    vs = V.toList $ unsafePerformIO (readIORef v)
match ids (PHeadTail hp tp) (List v) =
    V.length vs > 0 && match ids hp h && match ids tp t
  where
    vs = unsafePerformIO (readIORef v)
    h = V.head vs
    t = List (unsafePerformIO (newIORef (V.tail vs)))
match ids (PHeadTail hp tp) (String t) | not (T.null t) =
    match ids hp (Char (T.head t)) && match ids tp (String (T.tail t))
match ids (PPMKeyword ans aps) (Particle (PMKeyword bns mvs)) =
    ans == bns && matchParticle ids aps mvs
match _ _ _ = False

refMatch :: IDs -> ORef -> ORef -> Bool
refMatch ids x y = x == y || delegatesMatch
  where
    delegatesMatch = any
        (match ids (PMatch (Reference x)))
        (oDelegates (unsafePerformIO (readIORef y)))

-- | match multiple patterns with multiple values
matchAll :: IDs -> [Pattern] -> [Value] -> Bool
matchAll _ [] [] = True
matchAll ids (p:ps) (v:vs) = match ids p v && matchAll ids ps vs
matchAll _ _ _ = False

matchParticle :: IDs -> [Pattern] -> [Maybe Value] -> Bool
matchParticle _ [] [] = True
matchParticle ids (PAny:ps) (Nothing:mvs) = matchParticle ids ps mvs
matchParticle ids (PNamed _ p:ps) mvs = matchParticle ids (p:ps) mvs
matchParticle ids (p:ps) (Just v:mvs) =
    match ids p v && matchParticle ids ps mvs
matchParticle _ _ _ = False

-- | evaluate a method in a scope with the pattern's bindings, delegating to
-- the method's context and setting the "dispatch" object
runMethod :: Method -> Message -> VM Value
runMethod (Slot { mValue = v }) _ = return v
runMethod (Responder { mPattern = p, mContext = c, mExpr = e }) m = do
    nt <- newObject $ \o -> o
        { oDelegates = [c]
        , oMethods = (bindings p m, emptyMap)
        }

    modify $ \e' -> e'
        { call = Call
            { callSender = top e'
            , callMessage = m
            , callContext = c
            }
        }

    withTop nt $ eval e

-- | evaluate an action in a new scope
newScope :: VM Value -> VM Value
newScope x = do
    t <- gets top
    nt <- newObject $ \o -> o
        { oDelegates = [t]
        }

    withTop nt x

-- | given a pattern and a message, return the bindings from the pattern
bindings :: Pattern -> Message -> MethodMap
bindings (PSingle { ppTarget = p }) (Single { mTarget = t }) =
    toMethods (bindings' p t)
bindings (PKeyword { ppTargets = ps }) (Keyword { mTargets = ts }) =
    toMethods $ concat (zipWith bindings' ps ts)
bindings p m = error $ "impossible: bindings on " ++ show (p, m)

-- | given a pattern and avalue, return the bindings as a list of pairs
bindings' :: Pattern -> Value -> [(Pattern, Value)]
bindings' (PNamed n p) v = (psingle n PThis, v) : bindings' p v
bindings' (PPMKeyword _ ps) (Particle (PMKeyword _ mvs)) = concat
    $ map (\(p, Just v) -> bindings' p v)
    $ filter (isJust . snd)
    $ zip ps mvs
bindings' (PList ps) (List v) = concat (zipWith bindings' ps vs)
  where
    vs = V.toList $ unsafePerformIO (readIORef v)
bindings' (PHeadTail hp tp) (List v) =
    bindings' hp h ++ bindings' tp t
  where
    vs = unsafePerformIO (readIORef v)
    h = V.head vs
    t = List (unsafePerformIO (newIORef (V.tail vs)))
bindings' (PHeadTail hp tp) (String t) | not (T.null t) =
    bindings' hp (Char (T.head t)) ++ bindings' tp (String (T.tail t))
bindings' _ _ = []



-----------------------------------------------------------------------------
-- Helpers ------------------------------------------------------------------
-----------------------------------------------------------------------------

infixr 0 =:, =::

-- | define a method as an action returning a value
(=:) :: Pattern -> VM Value -> VM ()
pat =: vm = define pat (EVM Nothing vm)

-- | define a slot to a given value
(=::) :: Pattern -> Value -> VM ()
pat =:: v = define pat (Primitive Nothing v)

-- | define a method that evaluates e
(=:::) :: Pattern -> Expr -> VM ()
pat =::: e = define pat e

-- | find a value from an object, searching its delegates, throwing
-- a descriptive error if it is not found
findValue :: String -> (Value -> Bool) -> Value -> VM Value
findValue _ t v | t v = return v
findValue d t v = findValue' t v >>= maybe die return
  where
    die = throwError (ValueNotFound d v)

-- | findValue, but returning Nothing instead of failing
findValue' :: (Value -> Bool) -> Value -> VM (Maybe Value)
findValue' t v | t v = return (Just v)
findValue' t (Reference r) = do
    o <- liftIO (readIORef r)
    findDels (oDelegates o)
  where
    findDels [] = return Nothing
    findDels (d:ds) = do
        f <- findValue' t d
        case f of
            Nothing -> findDels ds
            Just v -> return (Just v)
findValue' _ _ = return Nothing

findBlock :: Value -> VM Value
{-# INLINE findBlock #-}
findBlock = findValue "Block" isBlock

findChar :: Value -> VM Value
{-# INLINE findChar #-}
findChar = findValue "Char" isChar

findContinuation :: Value -> VM Value
{-# INLINE findContinuation #-}
findContinuation = findValue "Continuation" isContinuation

findDouble :: Value -> VM Value
{-# INLINE findDouble #-}
findDouble = findValue "Double" isDouble

findExpression :: Value -> VM Value
{-# INLINE findExpression #-}
findExpression = findValue "Expression" isExpression

findHaskell :: Value -> VM Value
{-# INLINE findHaskell #-}
findHaskell = findValue "Haskell" isHaskell

findInteger :: Value -> VM Value
{-# INLINE findInteger #-}
findInteger = findValue "Integer" isInteger

findList :: Value -> VM Value
{-# INLINE findList #-}
findList = findValue "List" isList

findMessage :: Value -> VM Value
{-# INLINE findMessage #-}
findMessage = findValue "Message" isMessage

findMethod' :: Value -> VM Value
{-# INLINE findMethod' #-}
findMethod' = findValue "Method" isMethod

findParticle :: Value -> VM Value
{-# INLINE findParticle #-}
findParticle = findValue "Particle" isParticle

findProcess :: Value -> VM Value
{-# INLINE findProcess #-}
findProcess = findValue "Process" isProcess

findPattern :: Value -> VM Value
{-# INLINE findPattern #-}
findPattern = findValue "Pattern" isPattern

findReference :: Value -> VM Value
{-# INLINE findReference #-}
findReference = findValue "Reference" isReference

findString :: Value -> VM Value
{-# INLINE findString #-}
findString = findValue "String" isString

getString :: Expr -> VM String
getString e = eval e >>= fmap fromString . findString

getText :: Expr -> VM T.Text
getText e = eval e >>= findString >>= \(String t) -> return t

getList :: Expr -> VM [Value]
getList = fmap V.toList . getVector

getVector :: Expr -> VM (V.Vector Value)
getVector e = eval e
    >>= findList
    >>= \(List v) -> liftIO . readIORef $ v

here :: String -> VM Value
here n =
    gets top
        >>= dispatch . (single n)

bool :: Bool -> VM Value
{-# INLINE bool #-}
bool True = here "True"
bool False = here "False"

ifVM :: VM Value -> VM a -> VM a -> VM a
ifVM c a b = do
    true <- bool True
    r <- c

    if r == true
        then a
        else b

ifE :: Expr -> VM a -> VM a -> VM a
ifE = ifVM . eval

referenceTo :: Value -> VM Value
{-# INLINE referenceTo #-}
referenceTo = fmap Reference . orefFor

doBlock :: MethodMap -> Value -> [Expr] -> VM Value
{-# INLINE doBlock #-}
doBlock bms s es = do
    blockScope <- newObject $ \o -> o
        { oDelegates = [s]
        , oMethods = (bms, emptyMap)
        }

    withTop blockScope (evalAll es)

objectFor :: Value -> VM Object
{-# INLINE objectFor #-}
objectFor v = orefFor v >>= liftIO . readIORef

orefFor :: Value -> VM ORef
{-# INLINE orefFor #-}
orefFor v = gets primitives >>= \is -> return $ orefFrom is v

orefFrom :: IDs -> Value -> ORef
{-# INLINE orefFrom #-}
orefFrom _ (Reference r) = r
orefFrom ids (Block _ _ _) = idBlock ids
orefFrom ids (Char _) = idChar ids
orefFrom ids (Continuation _) = idContinuation ids
orefFrom ids (Double _) = idDouble ids
orefFrom ids (Expression _) = idExpression ids
orefFrom ids (Haskell _) = idHaskell ids
orefFrom ids (Integer _) = idInteger ids
orefFrom ids (List _) = idList ids
orefFrom ids (Message _) = idMessage ids
orefFrom ids (Method _) = idMethod ids
orefFrom ids (Particle _) = idParticle ids
orefFrom ids (Process _ _) = idProcess ids
orefFrom ids (Pattern _) = idPattern ids
orefFrom ids (String _) = idString ids

-- load a file, remembering it to prevent repeated loading
-- searches with cwd as lowest priority
requireFile :: FilePath -> VM Value
requireFile fn = do
    initialPath <- gets loadPath
    file <- findFile (initialPath ++ [""]) fn

    alreadyLoaded <- gets ((file `elem`) . loaded)
    if alreadyLoaded
        then return (particle "already-loaded")
        else do

    modify $ \s -> s { loaded = file : loaded s }

    doLoad file

-- load a file
-- searches with cwd as highest priority
loadFile :: FilePath -> VM Value
loadFile fn = do
    initialPath <- gets loadPath
    findFile ("":initialPath) fn >>= doLoad

-- execute a file
doLoad :: FilePath -> VM Value
doLoad file =
    case takeExtension file of
        ".hs" -> do
            int <- liftIO . H.runInterpreter $ do
                H.loadModules [file]
                H.setTopLevelModules ["Main"]
                H.interpret "load" (H.as :: VM ())

            load <- either (throwError . ImportError) return int

            load

            return (particle "ok")

        _ -> do
            initialPath <- gets loadPath

            ast <- continuedParseFile file

            modify $ \s -> s
                { loadPath = [takeDirectory file]
                }

            r <- evalAll ast

            modify $ \s -> s
                { loadPath = initialPath
                }

            return r

-- | given a list of paths to search, find the file to load
-- attempts to find the filename with .atomo and .hs extensions
findFile :: [FilePath] -> FilePath -> VM FilePath
findFile [] fn = throwError (FileNotFound fn)
findFile (p:ps) fn = do
    check <- filterM (liftIO . doesFileExist . ((p </> fn) <.>)) exts

    case check of
        [] -> findFile ps fn
        (ext:_) -> liftIO (canonicalizePath $ p </> fn <.> ext)
  where
    exts = ["", "atomo", "hs"]

-- | does one value delegate to another?
delegatesTo :: Value -> Value -> VM Bool
delegatesTo f t = do
    o <- objectFor f
    delegatesTo' (oDelegates o)
  where
    delegatesTo' [] = return False
    delegatesTo' (d:ds)
        | t `elem` (d:ds) = return True
        | otherwise = do
            o <- objectFor d
            delegatesTo' (oDelegates o ++ ds)

-- | is one value an instance of, equal to, or a delegation to another?
-- for example, 1 is-a?: Integer, but 1 does not delegates-to?: Integer
isA :: Value -> Value -> VM Bool
isA x y = do
    xr <- orefFor x
    yr <- orefFor y

    if xr == yr
        then return True
        else do
            ds <- fmap oDelegates (objectFor x)
            isA' ds
  where
    isA' [] = return False
    isA' (d:ds) = do
        di <- isA d y
        if di
            then return True
            else isA' ds
