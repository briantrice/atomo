{-# LANGUAGE QuasiQuotes #-}
module Atomo.Kernel (load) where

import Data.IORef
import Data.List ((\\))
import Data.Maybe (isJust)
import qualified Data.IntMap as M

import Atomo.Debug
import Atomo.Environment
import Atomo.Haskell
import Atomo.Method
import Atomo.Pretty

import qualified Atomo.Kernel.Numeric as Numeric
import qualified Atomo.Kernel.List as List
import qualified Atomo.Kernel.String as String
import qualified Atomo.Kernel.Block as Block
import qualified Atomo.Kernel.Expression as Expression
import qualified Atomo.Kernel.Concurrency as Concurrency
import qualified Atomo.Kernel.Message as Message
import qualified Atomo.Kernel.Comparable as Comparable
import qualified Atomo.Kernel.Particle as Particle
import qualified Atomo.Kernel.Pattern as Pattern
import qualified Atomo.Kernel.Ports as Ports
import qualified Atomo.Kernel.Time as Time
import qualified Atomo.Kernel.Bool as Bool
import qualified Atomo.Kernel.Association as Association
import qualified Atomo.Kernel.Parameter as Parameter
import qualified Atomo.Kernel.Exception as Exception
import qualified Atomo.Kernel.Environment as Environment
import qualified Atomo.Kernel.Eco as Eco
import qualified Atomo.Kernel.Continuation as Continuation

load :: VM ()
load = do
    [$p|this|] =::: [$e|dispatch sender|]

    [$p|(x: Object) clone|] =: do
        x <- here "x"
        newObject $ \o -> o
            { oDelegates = [x]
            }

    [$p|(x: Object) delegates-to: (y: Object)|] =: do
        f <- here "x" >>= orefFor
        t <- here "y"

        from <- liftIO (readIORef f)
        liftIO $ writeIORef f (from { oDelegates = oDelegates from ++ [t] })

        return (particle "ok")

    [$p|(x: Object) delegates-to?: (y: Object)|] =: do
        x <- here "x"
        y <- here "y"
        delegatesTo x y >>= bool

    [$p|(x: Object) is-a?: (y: Object)|] =: do
        x <- here "x"
        y <- here "y"
        isA x y >>= bool

    [$p|(x: Object) responds-to?: (p: Particle)|] =: do
        x <- here "x"
        Particle p' <- here "p" >>= findParticle

        let completed =
                case p' of
                    PMKeyword ns mvs -> keyword ns (completeKP mvs [x])
                    PMSingle n -> single n x

        findMethod x completed
            >>= bool . isJust

    [$p|(s: String) as: String|] =::: [$e|s|]

    [$p|(x: Object) as: String|] =::: [$e|x show|]

    [$p|(s: String) as: Integer|] =: do
        s <- getString [$e|s|]
        return (Integer (read s))

    [$p|(s: String) as: Double|] =: do
        s <- getString [$e|s|]
        return (Double (read s))

    [$p|(s: String) as: Char|] =: do
        s <- getString [$e|s|]
        return (Char (read s))

    [$p|(x: Object) show|] =:
        fmap (string . show . pretty) (here "x")

    [$p|(x: Object) dump|] =: do
        x <- here "x"
        liftIO (putStrLn (prettyShow x))
        return x

    [$p|(t: Object) load: (fn: String)|] =: do
        t <- here "t"
        fn <- getString [$e|fn|]

        modify $ \s -> s { top = t }

        loadFile fn

        return (particle "ok")

    [$p|(t: Object) require: (fn: String)|] =: do
        t <- here "t"
        fn <- getString [$e|fn|]

        modify $ \s -> s { top = t }

        requireFile fn

        return (particle "ok")

    [$p|v do: (b: Block)|] =: do
        v <- here "v"
        b <- here "b" >>= findBlock
        joinWith v b []
        return v
    [$p|v do: (b: Block) with: (l: List)|] =: do
        v <- here "v"
        b <- here "b" >>= findBlock
        as <- getList [$e|l|]
        joinWith v b as
        return v

    [$p|v join: (b: Block)|] =: do
        v <- here "v"
        b <- here "b" >>= findBlock
        joinWith v b []
    [$p|v join: (b: Block) with: (l: List)|] =: do
        v <- here "v"
        b <- here "b" >>= findBlock
        as <- getList [$e|l|]
        joinWith v b as


    Association.load
    Bool.load
    Parameter.load
    Numeric.load
    List.load
    String.load
    Block.load
    Expression.load
    Concurrency.load
    Message.load
    Comparable.load
    Particle.load
    Pattern.load
    Ports.load
    Time.load
    Exception.load
    Environment.load
    Eco.load
    Continuation.load

    prelude


prelude :: VM ()
prelude = mapM_ eval [$es|
    v match: (b: Block) :=
        if: b contents empty?
            then: { raise: @(no-matches-for: v) }
            else: {
                es = b contents
                [p, e] = es head targets

                match = (p as: Pattern) matches?: v
                if: (match == @no)
                    then: {
                        v match: (Block new: es tail in: b context)
                    }
                    else: {
                        @(yes: obj) = match
                        obj join: (Block new: [e] in: b context)
                    }
            }
|]

joinWith :: Value -> Value -> [Value] -> VM Value
joinWith t (Block s ps bes) as
    | length ps > length as =
        throwError (BlockArity (length ps) (length as))
    | null as || null ps = do
        case t of
            Reference r -> do
                Object ds ms <- objectFor t
                blockScope <- newObject $ \o -> o
                    { oDelegates = ds ++ [s]
                    , oMethods = ms
                    }

                res <- withTop blockScope (evalAll bes)
                new <- objectFor blockScope
                liftIO $ writeIORef r new
                    { oDelegates = oDelegates new \\ [s]
                    , oMethods = oMethods new
                    }

                return res
            _ -> do
                blockScope <- newObject $ \o -> o
                    { oDelegates = [t, s]
                    }

                withTop blockScope (evalAll bes)
    | otherwise = do
        -- a toplevel scope with transient definitions
        pseudoScope <- newObject $ \o -> o
            { oMethods = (bs, M.empty)
            }

        case t of
            Reference r -> do
                Object ds ms <- objectFor t
                -- the original prototype, but without its delegations
                -- this is to prevent dispatch loops
                doppelganger <- newObject $ \o -> o
                    { oMethods = ms
                    }

                -- the main scope, methods are taken from here and merged with
                -- the originals. delegates to the pseudoscope and doppelganger
                -- so it has their methods in scope, but definitions go here
                blockScope <- newObject $ \o -> o
                    { oDelegates = pseudoScope : doppelganger : ds ++ [s]
                    }

                res <- withTop blockScope (evalAll bes)
                new <- objectFor blockScope
                liftIO (writeIORef r new
                    { oDelegates = oDelegates new \\ [pseudoScope, doppelganger, s]
                    , oMethods = merge ms (oMethods new)
                    })

                return res
            _ -> do
                blockScope <- newObject $ \o -> o
                    { oDelegates = [pseudoScope, t, s]
                    }

                withTop blockScope (evalAll bes)
  where
    bs = addMethod (Slot (psingle "this" PSelf) t) $
            toMethods . concat $ zipWith bindings' ps as

    merge (os, ok) (ns, nk) =
        ( foldl (flip addMethod) os (concat $ M.elems ns)
        , foldl (flip addMethod) ok (concat $ M.elems nk)
        )
joinWith _ v _ = error $ "impossible: joinWith on " ++ show v
