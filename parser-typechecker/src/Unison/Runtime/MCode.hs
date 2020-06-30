{-# language GADTs #-}
{-# language BangPatterns #-}
{-# language PatternGuards #-}
{-# language EmptyDataDecls #-}
{-# language PatternSynonyms #-}

module Unison.Runtime.MCode
  ( Args'(..)
  , Args(..)
  , MLit(..)
  , Instr(..)
  , Section(..)
  , Comb(..)
  , Ref(..)
  , UPrim1(..)
  , UPrim2(..)
  , BPrim1(..)
  , BPrim2(..)
  , Branch(..)
  , bcount
  , ucount
  , emitCombs
  , emitComb
  , prettyCombs
  , prettyComb
  ) where

import GHC.Stack (HasCallStack)

import Data.Bifunctor (bimap,first)
import Data.Coerce
import Data.List (partition)
import Data.Word (Word64)

import Data.Primitive.PrimArray

import qualified Data.Map.Strict as M
import Unison.Util.EnumContainers as EC

import Data.Text (Text)
import qualified Data.Text as Text

import Unison.Var (Var)
import Unison.ABT.Normalized (pattern TAbss)
import Unison.Reference (Reference)
import Unison.Referent (Referent)
import qualified Unison.Type as Rf
import qualified Unison.Runtime.IOSource as Rf
import Unison.Runtime.ANF
  ( ANormal
  , ANormalT
  , ANormalTF(..)
  , Branched(..)
  , Func(..)
  , Mem(..)
  , SuperNormal(..)
  , SuperGroup(..)
  , RTag
  , CTag
  , Tag(..)
  , packTags
  , pattern TVar
  , pattern TLit
  , pattern TApp
  , pattern TPrm
  , pattern THnd
  , pattern TFrc
  , pattern TShift
  , pattern TLets
  , pattern TName
  , pattern TTm
  , pattern TMatch
  )
import qualified Unison.Runtime.ANF as ANF
import Unison.Runtime.Foreign
import Unison.Util.Bytes as Bytes

import Network.Socket as SYS
  ( accept
  )
import Network.Simple.TCP as SYS
  ( HostPreference(..)
  , bindSock
  , connectSock
  , listenSock
  , closeSock
  , send
  , recv
  )
import System.IO as SYS
  ( BufferMode(..)
  , Handle
  , openFile
  , hClose
  , hGetBuffering
  , hSetBuffering
  , hIsEOF
  , hIsOpen
  , hIsSeekable
  , hSeek
  , hTell
  )
import Data.Text.IO as SYS
  ( hGetLine
  , hPutStr
  )
import Control.Concurrent as SYS
  ( threadDelay
  , killThread
  )
import Data.Time.Clock.POSIX as SYS
  ( getPOSIXTime
  , utcTimeToPOSIXSeconds
  )
import System.Directory as SYS
  ( getCurrentDirectory
  , setCurrentDirectory
  , getTemporaryDirectory
  , getDirectoryContents
  , doesPathExist
  -- , doesDirectoryExist
  , renameDirectory
  , removeFile
  , renameFile
  , createDirectoryIfMissing
  , removeDirectoryRecursive
  , getModificationTime
  , getFileSize
  )

-- This outlines some of the ideas/features in this core
-- language, and how they may be used to implement features of
-- the surface language.

-----------------------
-- Delimited control --
-----------------------

-- There is native support for delimited control operations in
-- the core language. This means we can:
--   1. delimit a block of code with an integer tagged prompt,
--      which corresponds to pushing a frame onto the
--      continuation with said tag
--   2. capture a portion of the continuation up to a particular
--      tag frame and turn it into a value, which _removes_ the
--      tag frame from the continuation in the process
--   3. push such a captured value back onto the continuation

-- TBD: Since the captured continuations in _delimited_ control
-- are (in this case impure) functions, it may make sense to make
-- the representation of functions support these captured
-- continuations directly.

-- The obvious use case of this feature is effects and handlers.
-- Delimiting a block with a prompt is part of installing a
-- handler for said block at least naively. The other part is
-- establishing the code that should be executed for each
-- operation to be handled.

-- It's important (I believe) in #2 that the prompt be removed
-- from the continuation by a control effect. The captured
-- continuation not being automatically delimited corresponds to
-- a shallow handler's obligation to re-establish the handling of
-- a re-invoked computation if it wishes to do so. The delimiter
-- being removed from the capturing code's continuation
-- corresponds to a handler being allowed to yield effects from
-- the same siganture that it is handling.

-- In special cases, it should be possible to omit use of control
-- effects in handlers. At the least, if a handler case resumes
-- the computation in tail position, it should be unnecessary to
-- capture the continuation at all. If all cases act this way, we
-- don't need a delimiter, because we will never capture.

-- TBD: it may make more sense to have prompt pushing be part of
-- some other construct, due to A-normal forms of the code.

-----------------------------
-- Unboxed sum-of-products --
-----------------------------

-- It is not usually stated this way, but one of the core
-- features of the STG machine is that functions/closures can
-- return unboxed sum-of-products types. This is actually the way
-- _all_ data types work in STG. The discriminee of a case
-- statement must eventually return by pushing several values
-- onto the stack (the product part) and specifying which branch
-- to return to (the sum part).

-- The way heap allocated data is produced is that an
-- intermediate frame may be in the continuation that grabs this
-- information from the local storage and puts it into the heap.
-- If this frame were omitted, only the unboxed component would
-- be left. Also, in STG, the heap allocated data is just a means
-- of reconstructing its unboxed analogue. Evaluating a heap
-- allocated data type value just results in pushing its stored
-- fields back on the stack, and immediately returning the tag.

-- The portion of this with the heap allocation frame omitted
-- seems to be a natural match for the case analysis portion of
-- handlers. A naive implementation of an effect algebra is as
-- the data type of the polynomial functor generated by the
-- signature, and handling corresponds to case analysis. However,
-- in a real implementation, we don't want a heap allocated
-- representation of this algebra, because its purpose is control
-- flow. Each operation will be handled once as it occurs, and we
-- won't save work by remembering some reified representation of
-- which operations were used.

-- Since handlers in unison are written as functions, it seems to
-- make sense to define a calling convention for unboxed
-- sum-of-products as arguments. Variable numbers of stack
-- positions could be pushed for such arguments, with tags
-- specifying which case is being provided.

-- TBD: sum arguments to a function correspond to a product of
-- functions, so it's possible that the calling convention for
-- these functions should be similar to returning to a case,
-- where we push arguments and then select which of several
-- pieces of code to jump to. This view also seems relevant to
-- the optimized implementation of certain forms of handler,
-- where we want effects to just directly select some code to
-- execute based on state that has been threaded to that point.

-- One thing to note: it probably does not make sense to
-- completely divide returns into unboxed returns and allocation
-- frames. The reason this works in STG is laziness. Naming a
-- computation with `let` does not do any evaluation, but it does
-- allocate space for its (boxed) result. The only thing that
-- _does_ demand evaluation is case analysis. So, if a value with
-- sum type is being evaluated, we know it must be about to be
-- unpacked, and it makes little sense to pack it on the stack,
-- though we can build a closure version of it in the writeback
-- location established by `let`.

-- By contrast, in unison a `let` of a sum type evaluates it
-- immediately, even if no one is analyzing it. So we might waste
-- work rearranging the stack with the unpacked contents when we
-- only needed the closure version to begin with. Instead, we
-- gain the ability to make the unpacking operation use no stack,
-- because we know what we are unpacking must be a value. Turning
-- boxed function calls into unboxed versions thus seems like a
-- situational optimization, rather than a universal calling
-- convention.

-------------------------------
-- Delimited Dynamic Binding --
-------------------------------

-- There is a final component to the implementation of ability
-- handlers in this runtime system, and that is dynamically
-- scoped variables associated to each prompt. Each prompt
-- corresponds to an ability signature, and `reset` to a handler
-- for said signature, but we need storage space for the code
-- installed by said handler. It is possible to implement
-- dynamically scoped variables entirely with delimited
-- continuations, but it is more efficient to keep track of the
-- storage directly when manipulating the continuations.

-- The dynamic scoping---and how it interacts with
-- continuations---corresponds to the nested structure of
-- handlers. Installing a handler establishes a variable scope,
-- shadowing outer scopes for the same prompt. Shifting, however,
-- can exit these scopes dynamically. So, for instance, if we
-- have a structure like:

--    reset 0 $ ...
--      reset 1 $ ...
--        reset 0 $ ...
--          shift 1 <E>

-- We have nested scopes 0>1>0, with the second 0 shadowing the
-- first. However, when we shift to 1, the inner 0 scope is
-- captured into the continuation, and uses of the 0 ability in
-- <E> will be handled by the outer handler until it is shadowed
-- again (and the captured continuation will re-establish the
-- shadowing).

-- Mutation of the variables is possible, but mutation only
-- affects the current scope. Essentially, the dynamic scoping is
-- of mutable references, and when scope changes, we switch
-- between different references, and the mutation of each
-- reference does not affect the others. The purpose of the
-- mutation is to enable more efficient implementation of
-- certain recursive, 'deep' handlers, since those can operate
-- more like stateful code than control operators.

data Args'
  = Arg1 !Int
  | Arg2 !Int !Int
  -- frame index of each argument to the function
  | ArgN {-# unpack #-} !(PrimArray Int)
  | ArgR !Int !Int

data Args
  = ZArgs
  | UArg1 !Int
  | UArg2 !Int !Int
  | BArg1 !Int
  | BArg2 !Int !Int
  | DArg2 !Int !Int
  | UArgR !Int !Int
  | BArgR !Int !Int
  | DArgR !Int !Int !Int !Int
  | BArgN !(PrimArray Int)
  | UArgN !(PrimArray Int)
  | DArgN !(PrimArray Int) !(PrimArray Int)
  | DArgV !Int !Int
  deriving (Show, Eq, Ord)

ucount, bcount :: Args -> Int

ucount (UArg1 _) = 1
ucount (UArg2 _ _) = 2
ucount (DArg2 _ _) = 1
ucount (UArgR _ l) = l
ucount (DArgR _ l _ _) = l
ucount _ = 0
{-# inline ucount #-}

bcount (BArg1 _) = 1
bcount (BArg2 _ _) = 2
bcount (DArg2 _ _) = 1
bcount (BArgR _ l) = l
bcount (DArgR _ _ _ l) = l
bcount (BArgN a) = sizeofPrimArray a
bcount _ = 0
{-# inline bcount #-}

data UPrim1
  = DECI | INCI | NEGI | SGNI | LZRO | TZRO | COMN
  | ABSF | EXPF | LOGF | SQRT
  | COSF | ACOS | COSH | ACSH
  | SINF | ASIN | SINH | ASNH
  | TANF | ATAN | TANH | ATNH
  | ITOF | NTOF | CEIL | FLOR | TRNF | RNDF
  deriving (Show, Eq, Ord)

data UPrim2
  = ADDI | SUBI | MULI | DIVI | MODI
  | ADDF | SUBF | MULF | DIVF | ATN2
  | SHLI | SHRI | SHRN | POWI
  | EQLI | LEQI | LEQN | EQLF | LEQF
  | POWF | LOGB | MAXF | MINF
  | ANDN | IORN | XORN
  deriving (Show, Eq, Ord)

data BPrim1
  = SIZT | USNC | UCNS
  | ITOT | NTOT | FTOT
  | TTOI | TTON | TTOF
  | SIZS
  deriving (Show, Eq, Ord)

data BPrim2
  = EQLU | CMPU
  | DRPT | CATT | TAKT
  | EQLT | LEQT | LEST
  | DRPS | CATS | TAKS | CONS | SNOC | IDXS
  deriving (Show, Eq, Ord)

data MLit
  = MI !Int
  | MD !Double
  | MT !Text
  | MM !Referent
  | MY !Reference
  deriving (Show, Eq, Ord)

-- Instructions for manipulating the data stack in the main portion of
-- a block
data Instr
  -- 1-argument unboxed primitive operations
  = UPrim1 !UPrim1 -- primitive instruction
           !Int    -- index of prim argument

  -- 2-argument unboxed primitive operations
  | UPrim2 !UPrim2 -- primitive instruction
           !Int    -- index of first prim argument
           !Int    -- index of second prim argument

  -- 1-argument primitive operations that may involve boxed values
  | BPrim1 !BPrim1
           !Int

  -- 2-argument primitive operations that may involve boxed values
  | BPrim2 !BPrim2
           !Int
           !Int

  -- Call out to a Haskell function. This is considerably slower
  -- for very simple operations, hence the primops.
  | ForeignCall !Bool        -- catch exceptions
                !ForeignFunc -- FFI call
                !Args        -- arguments

  -- Set the value of a dynamic reference
  | SetDyn !Word64 -- the prompt tag of the reference
           !Int -- the stack index of the closure to store

  -- Capture the continuation up to a given marker.
  | Capture !Word64 -- the prompt tag

  -- This is essentially the opposite of `Call`. Pack a given
  -- statically known function into a closure with arguments.
  -- No stack is necessary, because no nested evaluation happens,
  -- so the instruction directly takes a follow-up.
  | Name !Ref !Args

  -- Dump some debugging information about the machine state to
  -- the screen.
  | Info !String -- prefix for output

  -- Pack a data type value into a closure and place it
  -- on the stack.
  | Pack !Word64 -- tag
         !Args   -- arguments to pack

  -- Unpack the contents of a data type onto the stack
  | Unpack !Int -- stack index of data to unpack

  -- Push a particular value onto the appropriate stack
  | Lit !MLit -- value to push onto the stack

  -- Print a value on the unboxed stack
  | Print !Int -- index of the primitive value to print

  -- Put a delimiter on the continuation
  | Reset !(EnumSet Word64) -- prompt ids

  | Fork !Section
  | Seq !Args
  deriving (Show, Eq, Ord)

data Section
  -- Apply a function to arguments. This is the 'slow path', and
  -- handles applying functions from arbitrary sources. This
  -- requires checks to determine what exactly should happen.
  = App
      !Bool -- skip argument check for known calling convention
      !Ref  -- function to call
      !Args -- arguments

  -- This is the 'fast path', for when we statically know we're
  -- making an exactly saturated call to a statically known
  -- function. This allows skipping various checks that can cost
  -- time in very tight loops. This also allows skipping the
  -- stack check if we know that the current stack allowance is
  -- sufficient for where we're jumping to.
  | Call
      !Bool   -- skip stack check
      !Word64 -- global function reference
      !Args   -- arguments

  -- Jump to a captured continuation value.
  | Jump
      !Int  -- index of captured continuation
      !Args -- arguments to send to continuation

  -- Branch on the value in the unboxed data stack
  | Match !Int    -- index of unboxed item to match on
          !Branch -- branches

  -- Yield control to the current continuation, with arguments
  | Yield !Args -- values to yield

  -- Prefix an instruction onto a section
  | Ins !Instr !Section

  -- Sequence two sections. The second is pushed as a return
  -- point for the results of the first. Stack modifications in
  -- the first are lost on return to the second.
  | Let !Section !Section

  | Die String

  | Exit
  deriving (Show, Eq, Ord)

data Comb
  = Lam !Int -- Number of unboxed arguments
        !Int -- Number of boxed arguments
        !Int -- Maximum needed unboxed frame size
        !Int -- Maximum needed boxed frame size
        !Section -- Entry
  deriving (Show, Eq, Ord)

data Ref
  = Stk !Int    -- stack reference to a closure
  | Env !Word64 -- global environment reference to a combinator
  | Dyn !Word64 -- dynamic scope reference to a closure
  deriving (Show, Eq, Ord)

data Branch
  -- if tag == n then t else f
  = Test1 !Word64
          !Section
          !Section
  | Test2 !Word64 !Section -- if tag == m then ...
          !Word64 !Section -- else if tag == n then ...
          !Section         -- else ...
  | TestW !Section
          !(EnumMap Word64 Section)
  | TestT !Section
          !(M.Map Text Section)
  deriving (Show, Eq, Ord)

data Ctx v
  = ECtx
  | Block (Ctx v)
  | Tag (Ctx v)
  | Var v Mem (Ctx v)
  deriving (Show)

type RCtx v = M.Map v Word64

ctx :: [v] -> [Mem] -> Ctx v
ctx vs cs = pushCtx (zip vs cs) ECtx

ctxResolve :: Var v => Ctx v -> v -> Maybe (Int,Mem)
ctxResolve ctx v = walk 0 0 ctx
  where
  walk _ _ ECtx = Nothing
  walk ui bi (Block ctx) = walk ui bi ctx
  walk ui bi (Tag ctx) = walk (ui+1) bi ctx
  walk ui bi (Var x m ctx)
    | v == x = case m of BX -> Just (bi,m) ; UN -> Just (ui,m)
    | otherwise = walk ui' bi' ctx
    where
    (ui', bi') = case m of BX -> (ui,bi+1) ; UN -> (ui+1,bi)

pushCtx :: [(v,Mem)] -> Ctx v -> Ctx v
pushCtx new old = foldr (uncurry Var) old new

catCtx :: Ctx v -> Ctx v -> Ctx v
catCtx ECtx r = r
catCtx (Tag l) r = Tag $ catCtx l r
catCtx (Block l) r = Block $ catCtx l r
catCtx (Var v m l) r = Var v m $ catCtx l r

breakAfter :: Eq v => (v -> Bool) -> Ctx v -> (Ctx v, Ctx v)
breakAfter _ ECtx = (ECtx, ECtx)
breakAfter p (Tag vs) = first Tag $ breakAfter p vs
breakAfter p (Block vs) = first Block $ breakAfter p vs
breakAfter p (Var v m vs) = (Var v m lvs, rvs)
  where
  (lvs, rvs)
    | p v       = (ECtx, vs)
    | otherwise = breakAfter p vs

sumCtx :: Var v => Ctx v -> v -> [(v,Mem)] -> Ctx v
sumCtx ctx v vcs
  | (lctx, rctx) <- breakAfter (== v) ctx
  = catCtx lctx $ pushCtx vcs rctx

rctxResolve :: Var v => RCtx v -> v -> Maybe Word64
rctxResolve ctx u = M.lookup u ctx

emitCombs
  :: Var v => Word64 -> SuperGroup v
  -> (Comb, EnumMap Word64 Comb, Word64)
emitCombs frsh (Rec grp ent)
  = (emitComb rec ent, EC.mapFromList aux, frsh')
  where
  frsh' = frsh + fromIntegral (length grp)
  (rvs, cmbs) = unzip grp
  rec = M.fromList $ zip rvs [frsh..]
  aux = zip [frsh..] $ emitComb rec <$> cmbs

emitComb :: Var v => RCtx v -> SuperNormal v -> Comb
emitComb rec (Lambda ccs (TAbss vs bd))
  = Lam 0 (length vs) 10 10 $ emitSection rec (ctx vs ccs) bd

emitSection :: Var v => RCtx v -> Ctx v -> ANormal v -> Section
emitSection rec ctx (TLets us ms bu bo)
  = emitLet rec ctx bu $ emitSection rec ectx bo
  where
  ectx = pushCtx (zip us ms) ctx
emitSection rec ctx (TName u (Left f) args bo)
  = emitClosures rec ctx args $ \ctx as
 -> Ins (Name (Env f) as)
  $ emitSection rec (Var u BX ctx) bo
emitSection rec ctx (TName u (Right v) args bo)
  | Just (i,BX) <- ctxResolve ctx v
  = emitClosures rec ctx args $ \ctx as
 -> Ins (Name (Stk i) as)
  $ emitSection rec (Var u BX ctx) bo
  | Just n <- rctxResolve rec v
  = emitClosures rec ctx args $ \ctx as
 -> Ins (Name (Env n) as)
  $ emitSection rec (Var u BX ctx) bo
  | otherwise = emitSectionVErr v
emitSection rec ctx (TVar v)
  | Just (i,BX) <- ctxResolve ctx v = Yield $ BArg1 i
  | Just (i,UN) <- ctxResolve ctx v = Yield $ UArg1 i
  | Just j <- rctxResolve rec v = App False (Env j) ZArgs
  | otherwise = emitSectionVErr v
emitSection _   _   (TPrm ANF.EROR [])
  = Die "error call"
emitSection _   ctx (TPrm p args)
  = Ins (emitPOp p $ emitArgs ctx args)
  . Yield $ DArgV i j
  where
  (i, j) = countBlock ctx
emitSection rec ctx (TApp f args)
  = emitClosures rec ctx args $ \ctx as
 -> emitFunction rec ctx f as
emitSection _   _   (TLit l)
  = Ins (emitLit l)
  . Yield $ litArg l
emitSection rec ctx (TMatch v bs)
  | Just (i,BX) <- ctxResolve ctx v
  , MatchData _ cs df <- bs
  = Ins (Unpack i)
  $ emitDataMatching rec ctx cs df
  | Just (i,BX) <- ctxResolve ctx v
  , MatchRequest hs <- bs
  = Ins (Unpack i)
  $ emitRequestMatching rec ctx hs
  | Just (i,UN) <- ctxResolve ctx v
  , MatchIntegral cs df <- bs
  = emitIntegralMatching rec ctx i cs df
  | Just (i,BX) <- ctxResolve ctx v
  , MatchText cs df <- bs
  = emitTextMatching rec ctx i cs df
  | Just (i,UN) <- ctxResolve ctx v
  , MatchSum cs <- bs
  = emitSumMatching rec ctx v i cs
  | Just (_,cc) <- ctxResolve ctx v
  = error
  $ "emitSection: mismatched calling convention for match: "
  ++ matchCallingError cc bs
  | otherwise
  = error
  $ "emitSection: could not resolve match variable: " ++ show (ctx,v)
emitSection rec ctx (THnd rts h df b)
  | Just (i,BX) <- ctxResolve ctx h
  = Ins (Reset . EC.setFromList $ rs)
  $ flip (foldr (\r -> Ins (SetDyn r i))) rs
  $ maybe id (\(TAbss us d) l ->
      Let l $ emitSection rec (pushCtx ((,BX) <$> us) ctx) d) df
  $ emitSection rec ctx b
  | otherwise = emitSectionVErr h
  where
  rs = rawTag <$> rts
emitSection rec ctx (TShift i v e)
  = Ins (Capture $ rawTag i)
  $ emitSection rec (Var v BX ctx) e
emitSection _   ctx (TFrc v)
  | Just (i,BX) <- ctxResolve ctx v = App False (Stk i) ZArgs
  | Just _ <- ctxResolve ctx v = error
  $ "emitSection: values to be forced must be boxed: " ++ show v
  | otherwise = emitSectionVErr v
emitSection _ _ tm = error $ "emitSection: unhandled code: " ++ show tm

emitFunction :: Var v => RCtx v -> Ctx v -> Func v -> Args -> Section
emitFunction rec ctx (FVar v) as
  | Just (i,BX) <- ctxResolve ctx v
  = App False (Stk i) as
  | Just j <- rctxResolve rec v
  = App False (Env j) as
  | otherwise = emitSectionVErr v
emitFunction _   _   (FComb n) as
  | False -- known saturated call
  = Call False n as
  | False -- known unsaturated call
  = Ins (Name (Env n) as) $ Yield (BArg1 0)
  | otherwise -- slow path
  = App False (Env n) as
emitFunction _   _   (FCon r t) as
  = Ins (Pack (packTags r t) as)
  . Yield $ BArg1 0
emitFunction _   _   (FReq a e) as
  -- Currently implementing packed calling convention for abilities
  = Ins (Lit (MI . fromIntegral $ rawTag e))
  . Ins (Pack (rawTag a) (reqArgs as))
  . App True (Dyn $ rawTag a) $ BArg1 0
emitFunction _   ctx (FCont k) as
  | Just (i, BX) <- ctxResolve ctx k = Jump i as
  | Nothing <- ctxResolve ctx k = emitFunctionVErr k
  | otherwise = error $ "emitFunction: continuations are boxed"
emitFunction _ _ (FPrim _) _
  = error "emitFunction: impossible"

reqArgs :: Args -> Args
reqArgs = \case
  ZArgs -> UArg1 0
  UArg1 i -> UArg2 0 (i+1)
  UArg2 i j
    | i == 0 && j == 1 -> UArgR 0 3
    | otherwise -> UArgN (fl [0,i+1,j+1])
  BArg1 i -> DArg2 0 i
  BArg2 i j
    | j == i+1 -> DArgR 0 1 i 2
    | otherwise -> DArgN (fl [0]) (fl [i,j])
  DArg2 i j
    | i == 0 -> DArgR 0 2 j 1
    | otherwise -> DArgN (fl [0,i+1]) (fl [j])
  UArgR i l
    | i == 0 -> UArgR 0 (l+1)
    | otherwise -> UArgN (fl $ [0] ++ Prelude.take l [i+1..])
  BArgR i l -> DArgR 0 1 i l
  DArgR ui ul bi bl
    | ui == 0 -> DArgR 0 (ul+1) bi bl
    | otherwise -> DArgN (fl $ [0] ++ Prelude.take ul [ui+1..])
                        (fl $ Prelude.take bl [bi..])
  UArgN us -> UArgN (fl $ [0] ++ fmap (+1) (tl us))
  BArgN bs -> DArgN (fl [0]) bs
  DArgN us bs -> DArgN (fl $ [0] ++ fmap (+1) (tl us)) bs
  DArgV i j -> DArgV i j
  where
  fl = primArrayFromList
  tl = primArrayToList

countBlock :: Ctx v -> (Int, Int)
countBlock = go 0 0
  where
  go !ui !bi (Var _ UN ctx) = go (succ ui) bi ctx
  go  ui  bi (Var _ BX ctx) = go ui (succ bi) ctx
  go  ui  bi (Tag ctx)      = go (succ ui) bi ctx
  go  ui  bi _              = (ui, bi)

matchCallingError :: Mem -> Branched v -> String
matchCallingError cc b = "(" ++ show cc ++ "," ++ brs ++ ")"
  where
  brs | MatchData _ _ _ <- b = "MatchData"
      | MatchEmpty <- b = "MatchEmpty"
      | MatchIntegral _ _ <- b = "MatchIntegral"
      | MatchRequest _ <- b = "MatchRequest"
      | MatchSum _ <- b = "MatchSum"
      | MatchText _ _ <- b = "MatchText"

emitSectionVErr :: (Var v, HasCallStack) => v -> a
emitSectionVErr v
  = error
  $ "emitSection: could not resolve function variable: " ++ show v

emitFunctionVErr :: (Var v, HasCallStack) => v -> a
emitFunctionVErr v
  = error
  $ "emitFunction: could not resolve function variable: " ++ show v

litArg :: ANF.Lit -> Args
litArg ANF.T{} = BArg1 0
litArg ANF.LM{} = BArg1 0
litArg ANF.LY{} = BArg1 0
litArg _       = UArg1 0

emitLet :: Var v => RCtx v -> Ctx v -> ANormalT v -> Section -> Section
-- Currently packed literals
emitLet _   _   (ALit l)
  = Ins (emitLit l)
emitLet _    ctx (AApp (FComb n) args)
  -- We should be able to tell if we are making a saturated call
  -- or not here. We aren't carrying the information here yet, though.
  | False -- not saturated
  = Ins . Name (Env n) $ emitArgs ctx args
emitLet _   ctx (AApp (FCon r n) args)
  = Ins . Pack (packTags r n) $ emitArgs ctx args
emitLet _   ctx (AApp (FPrim p) args)
  = Ins . either emitPOp emitIOp p $ emitArgs ctx args
emitLet rec ctx bnd = Let (emitSection rec (Block ctx) (TTm bnd))

-- Float
emitPOp :: ANF.POp -> Args -> Instr
emitPOp ANF.ADDI = emitP2 ADDI
emitPOp ANF.ADDN = emitP2 ADDI
emitPOp ANF.SUBI = emitP2 SUBI
emitPOp ANF.SUBN = emitP2 SUBI
emitPOp ANF.MULI = emitP2 MULI
emitPOp ANF.MULN = emitP2 MULI
emitPOp ANF.DIVI = emitP2 DIVI
emitPOp ANF.DIVN = emitP2 DIVI
emitPOp ANF.MODI = emitP2 MODI -- TODO: think about how these behave
emitPOp ANF.MODN = emitP2 MODI -- TODO: think about how these behave
emitPOp ANF.POWI = emitP2 POWI
emitPOp ANF.POWN = emitP2 POWI
emitPOp ANF.SHLI = emitP2 SHLI
emitPOp ANF.SHLN = emitP2 SHLI -- Note: left shift behaves uniformly
emitPOp ANF.SHRI = emitP2 SHRI
emitPOp ANF.SHRN = emitP2 SHRN
emitPOp ANF.LEQI = emitP2 LEQI
emitPOp ANF.LEQN = emitP2 LEQN
emitPOp ANF.EQLI = emitP2 EQLI
emitPOp ANF.EQLN = emitP2 EQLI

emitPOp ANF.SGNI = emitP1 SGNI
emitPOp ANF.NEGI = emitP1 NEGI
emitPOp ANF.INCI = emitP1 INCI
emitPOp ANF.INCN = emitP1 INCI
emitPOp ANF.DECI = emitP1 DECI
emitPOp ANF.DECN = emitP1 DECI
emitPOp ANF.TZRO = emitP1 TZRO
emitPOp ANF.LZRO = emitP1 LZRO
emitPOp ANF.ANDN = emitP2 ANDN
emitPOp ANF.IORN = emitP2 IORN
emitPOp ANF.XORN = emitP2 XORN
emitPOp ANF.COMN = emitP1 COMN

emitPOp ANF.ADDF = emitP2 ADDF
emitPOp ANF.SUBF = emitP2 SUBF
emitPOp ANF.MULF = emitP2 MULF
emitPOp ANF.DIVF = emitP2 DIVF
emitPOp ANF.LEQF = emitP2 LEQF
emitPOp ANF.EQLF = emitP2 EQLF

emitPOp ANF.MINF = emitP2 MINF
emitPOp ANF.MAXF = emitP2 MAXF

emitPOp ANF.POWF = emitP2 POWF
emitPOp ANF.EXPF = emitP1 EXPF
emitPOp ANF.ABSF = emitP1 ABSF
emitPOp ANF.SQRT = emitP1 SQRT
emitPOp ANF.LOGF = emitP1 LOGF
emitPOp ANF.LOGB = emitP2 LOGB

emitPOp ANF.CEIL = emitP1 CEIL
emitPOp ANF.FLOR = emitP1 FLOR
emitPOp ANF.TRNF = emitP1 TRNF
emitPOp ANF.RNDF = emitP1 RNDF

emitPOp ANF.COSF = emitP1 COSF
emitPOp ANF.SINF = emitP1 SINF
emitPOp ANF.TANF = emitP1 TANF
emitPOp ANF.COSH = emitP1 COSH
emitPOp ANF.SINH = emitP1 SINH
emitPOp ANF.TANH = emitP1 TANH
emitPOp ANF.ACOS = emitP1 ACOS
emitPOp ANF.ATAN = emitP1 ATAN
emitPOp ANF.ASIN = emitP1 ASIN
emitPOp ANF.ACSH = emitP1 ACSH
emitPOp ANF.ASNH = emitP1 ASNH
emitPOp ANF.ATNH = emitP1 ATNH
emitPOp ANF.ATN2 = emitP2 ATN2

emitPOp ANF.ITOF = emitP1 ITOF
emitPOp ANF.NTOF = emitP1 NTOF
emitPOp ANF.ITOT = emitBP1 ITOT
emitPOp ANF.NTOT = emitBP1 NTOT
emitPOp ANF.FTOT = emitBP1 FTOT
emitPOp ANF.TTON = emitBP1 TTON
emitPOp ANF.TTOI = emitBP1 TTOI
emitPOp ANF.TTOF = emitBP1 TTOF

emitPOp ANF.CATT = emitBP2 CATT
emitPOp ANF.TAKT = emitBP2 TAKT
emitPOp ANF.DRPT = emitBP2 DRPT
emitPOp ANF.SIZT = emitBP1 SIZT
emitPOp ANF.UCNS = emitBP1 UCNS
emitPOp ANF.USNC = emitBP1 USNC
emitPOp ANF.EQLT = emitBP2 EQLT
emitPOp ANF.LEQT = emitBP2 LEQT

emitPOp ANF.CATS = emitBP2 CATS
emitPOp ANF.TAKS = emitBP2 TAKS
emitPOp ANF.DRPS = emitBP2 DRPS
emitPOp ANF.SIZS = emitBP1 SIZS
emitPOp ANF.CONS = emitBP2 CONS
emitPOp ANF.SNOC = emitBP2 SNOC
emitPOp ANF.IDXS = emitBP2 IDXS

emitPOp ANF.EQLU = emitBP2 EQLU
emitPOp ANF.CMPU = emitBP2 CMPU

emitPOp ANF.BLDS = Seq
emitPOp ANF.FORK = \case
  BArg1 i -> Fork $ App True (Stk i) ZArgs
  _ -> error "fork takes exactly one boxed argument"
emitPOp ANF.PRNT = \case
  UArg1 i -> Print i
  _ -> error "print takes exactly one unboxed argument"
emitPOp ANF.INFO = \case
  ZArgs -> Info "debug"
  _ -> error "info takes no arguments"
-- handled in emitSection because Die is not an instruction
emitPOp ANF.EROR = error "error takes zero arguments"

emitIOp :: ANF.IOp -> Args -> Instr
emitIOp iop = ForeignCall True (iopToForeign iop)

bufferModeResult :: BufferMode -> ForeignRslt
bufferModeResult NoBuffering = [Left 0]
bufferModeResult LineBuffering = [Left 1]
bufferModeResult (BlockBuffering Nothing) = [Left 3]
bufferModeResult (BlockBuffering (Just n)) = [Left 4, Left n]

booleanResult :: Bool -> ForeignRslt
booleanResult b = [Left $ fromEnum b]

intResult :: Int -> ForeignRslt
intResult i = [Left i]

-- TODO: this seems questionable, but the existing IO source is
-- saying that these things return Nat, not arbitrary precision
-- integers.
intg2natResult :: Integer -> ForeignRslt
intg2natResult i = [Left $ fromInteger i]

stringResult :: String -> ForeignRslt
stringResult = wrappedResult Rf.textRef . Text.pack

wrappedResult :: Reference -> a -> ForeignRslt
wrappedResult r x = [Right $ Wrap r x]

handleResult :: Handle -> ForeignRslt
handleResult h = [Right $ Wrap Rf.handleReference h]

timeResult :: RealFrac r => r -> ForeignRslt
timeResult t = intResult $ round t

maybeResult'
  :: (a -> (Int, ForeignRslt)) -> Maybe a -> ForeignRslt
maybeResult' _ Nothing = [Left 0]
maybeResult' f (Just x)
  | (i, r) <- f x = Left (i+1) : r


iopToForeign :: ANF.IOp -> ForeignFunc
iopToForeign ANF.OPENFI
  = foreign2 $ \fp mo -> handleResult <$> openFile fp mo
iopToForeign ANF.CLOSFI
  = foreign1 $ \h -> [] <$ hClose h
iopToForeign ANF.ISFEOF
  = foreign1 $ \h -> booleanResult <$> hIsEOF h
iopToForeign ANF.ISFOPN
  = foreign1 $ \h -> booleanResult <$> hIsOpen h
iopToForeign ANF.ISSEEK
  = foreign1 $ \h -> booleanResult <$> hIsSeekable h
iopToForeign ANF.SEEKFI
  = foreign3 $ \h sm n -> [] <$ hSeek h sm (fromIntegral (n :: Int))
iopToForeign ANF.POSITN
  = foreign1 $ \h -> intg2natResult <$> hTell h
iopToForeign ANF.GBUFFR
  = foreign1 $ \h -> bufferModeResult <$> hGetBuffering h
iopToForeign ANF.SBUFFR
  = foreign2 $ \h bm -> [] <$ hSetBuffering h bm
iopToForeign ANF.GTLINE
  = foreign1 $ \h -> wrappedResult Rf.textRef <$> hGetLine h
iopToForeign ANF.GTTEXT
  = error "todo" -- foreign1 $ \h -> pure . Right . Wrap <$> hGetText h
iopToForeign ANF.PUTEXT
  = foreign2 $ \h t -> [] <$ hPutStr h t
iopToForeign ANF.SYTIME
  = foreign0 $ timeResult <$> getPOSIXTime
iopToForeign ANF.GTMPDR
  = foreign0 $ stringResult <$> getTemporaryDirectory
iopToForeign ANF.GCURDR
  = foreign0 $ stringResult <$> getCurrentDirectory
iopToForeign ANF.SCURDR
  = foreign1 $ \fp -> [] <$ setCurrentDirectory (Text.unpack fp)
iopToForeign ANF.DCNTNS
  = foreign1 $ \fp ->
      error "todo" <$ getDirectoryContents (Text.unpack fp)
iopToForeign ANF.FEXIST
  = foreign1 $ \fp -> booleanResult <$> doesPathExist (Text.unpack fp)
iopToForeign ANF.ISFDIR = error "todo"
iopToForeign ANF.CRTDIR
  = foreign1 $ \fp ->
      [] <$ createDirectoryIfMissing True (Text.unpack fp)
iopToForeign ANF.REMDIR
  = foreign1 $ \fp -> [] <$ removeDirectoryRecursive (Text.unpack fp)
iopToForeign ANF.RENDIR
  = foreign2 $ \fmp top ->
      [] <$ renameDirectory (Text.unpack fmp) (Text.unpack top)
iopToForeign ANF.REMOFI
  = foreign1 $ \fp -> [] <$ removeFile (Text.unpack fp)
iopToForeign ANF.RENAFI
  = foreign2 $ \fmp top ->
      [] <$ renameFile (Text.unpack fmp) (Text.unpack top)
iopToForeign ANF.GFTIME
  = foreign1 $ \fp ->
      timeResult . utcTimeToPOSIXSeconds
        <$> getModificationTime (Text.unpack fp)
iopToForeign ANF.GFSIZE
  = foreign1 $ \fp -> intg2natResult <$> getFileSize (Text.unpack fp)
iopToForeign ANF.SRVSCK
  = foreign2 $ \mhst port ->
      wrappedResult Rf.socketReference
        <$> SYS.bindSock (hostPreference mhst) (Text.unpack port)
iopToForeign ANF.LISTEN
  = foreign1 $ \sk ->
      [] <$ SYS.listenSock sk 2048
iopToForeign ANF.CLISCK
  = foreign2 $ \ho po ->
      wrappedResult Rf.socketReference
        <$> SYS.connectSock (Text.unpack ho) (Text.unpack po)
iopToForeign ANF.CLOSCK
  = foreign1 $ \sk -> [] <$ SYS.closeSock sk
iopToForeign ANF.SKACPT
  = foreign1 $ \sk ->
      wrappedResult Rf.socketReference <$> SYS.accept sk
iopToForeign ANF.SKSEND
  = foreign2 $ \sk bs ->
      [] <$ SYS.send sk (Bytes.toByteString bs)
iopToForeign ANF.SKRECV
  = foreign2 $ \hs n ->
      maybeResult' ((0,) . wrappedResult Rf.bytesRef)
        . fmap Bytes.fromByteString
        <$> SYS.recv hs n
iopToForeign ANF.THKILL
  = foreign1 $ \tid -> [] <$ killThread tid
iopToForeign ANF.THDELY
  = foreign1 $ \n -> [] <$ threadDelay n

hostPreference :: Maybe Text -> SYS.HostPreference
hostPreference Nothing = SYS.HostAny
hostPreference (Just host) = SYS.Host $ Text.unpack host

emitP1 :: UPrim1 -> Args -> Instr
emitP1 p (UArg1 i) = UPrim1 p i
emitP1 p a
  = error $ "wrong number of args for unary unboxed primop: "
         ++ show (p, a)

emitP2 :: UPrim2 -> Args -> Instr
emitP2 p (UArg2 i j) = UPrim2 p i j
emitP2 p a
  = error $ "wrong number of args for binary unboxed primop: "
         ++ show (p, a)

emitBP1 :: BPrim1 -> Args -> Instr
emitBP1 p (UArg1 i) = BPrim1 p i
emitBP1 p (BArg1 i) = BPrim1 p i
emitBP1 p a
  = error $ "wrong number of args for unary boxed primop: "
         ++ show (p,a)

emitBP2 :: BPrim2 -> Args -> Instr
emitBP2 p (UArg2 i j) = BPrim2 p i j
emitBP2 p (BArg2 i j) = BPrim2 p i j
emitBP2 p (DArg2 i j) = BPrim2 p i j
emitBP2 p a
  = error $ "wrong number of args for binary boxed primop: "
         ++ show (p,a)

emitDataMatching
  :: Var v
  => RCtx v
  -> Ctx v
  -> EnumMap CTag ([Mem], ANormal v)
  -> Maybe (ANormal v)
  -> Section
emitDataMatching rec ctx cs df
  = Match 0 . TestW edf . coerce $ fmap (emitCase rec ctx) cs
  where
  edf | Just co <- df = emitSection rec ctx co
      | otherwise = Die "missing data case"

emitSumMatching
  :: Var v
  => RCtx v
  -> Ctx v
  -> v
  -> Int
  -> EnumMap Word64 ([Mem], ANormal v)
  -> Section
emitSumMatching rec ctx v i cs
  = Match i . TestW edf $ fmap (emitSumCase rec ctx v) cs
  where
  edf = Die "uncovered unboxed sum case"

emitRequestMatching
  :: Var v
  => RCtx v
  -> Ctx v
  -> EnumMap RTag (EnumMap CTag ([Mem], ANormal v))
  -> Section
emitRequestMatching rec ctx hs
  = Match 0 . TestW edf . coerce $ fmap f hs
  where
  f cs = Match 1 . TestW edf . coerce $ fmap (emitCase rec ctx) cs
  edf = Die "unhandled ability"

emitIntegralMatching
  :: Var v
  => RCtx v
  -> Ctx v
  -> Int
  -> EnumMap Word64 (ANormal v)
  -> Maybe (ANormal v)
  -> Section
emitIntegralMatching rec ctx i cs df
  = Match i . TestW edf $ fmap (emitCase rec ctx . ([],)) cs
  where
  edf | Just co <- df = emitSection rec ctx co
      | otherwise = Die "missing integral case"

emitTextMatching
  :: Var v
  => RCtx v
  -> Ctx v
  -> Int
  -> M.Map Text (ANormal v)
  -> Maybe (ANormal v)
  -> Section
emitTextMatching rec ctx i cs df
  = Match i . TestT edf $ fmap (emitCase rec ctx . ([],)) cs
  where
  edf | Just co <- df = emitSection rec ctx co
      | otherwise = Die "missing text case"

emitCase :: Var v => RCtx v -> Ctx v -> ([Mem], ANormal v) -> Section
emitCase rec ctx (ccs, TAbss vs bo)
  = emitSection rec (Tag $ pushCtx (zip vs ccs) ctx) bo

emitSumCase
  :: Var v => RCtx v -> Ctx v -> v -> ([Mem], ANormal v) -> Section
emitSumCase rec ctx v (ccs, TAbss vs bo)
  = emitSection rec (sumCtx ctx v $ zip vs ccs) bo

emitLit :: ANF.Lit -> Instr
emitLit l = Lit $ case l of
  ANF.I i -> MI $ fromIntegral i
  ANF.N n -> MI $ fromIntegral n
  ANF.C c -> MI $ fromEnum c
  ANF.F d -> MD d
  ANF.T t -> MT t
  ANF.LM r -> MM r
  ANF.LY r -> MY r

emitClosures
  :: Var v
  => RCtx v -> Ctx v -> [v]
  -> (Ctx v -> Args -> Section)
  -> Section
emitClosures rec ctx args k
  = allocate ctx args $ \ctx -> k ctx $ emitArgs ctx args
  where
  allocate ctx [] k = k ctx
  allocate ctx (a:as) k
    | Just _ <- ctxResolve ctx a = allocate ctx as k
    | Just n <- rctxResolve rec a
    = Ins (Name (Env n) ZArgs) $ allocate (Var a BX ctx) as k
    | otherwise
    = error $ "emitClosures: unknown reference: " ++ show a

emitArgs :: Var v => Ctx v -> [v] -> Args
emitArgs ctx args
  | Just l <- traverse (ctxResolve ctx) args = demuxArgs l
  | otherwise
  = error $ "could not resolve argument variables: " ++ show args

demuxArgs :: [(Int,Mem)] -> Args
demuxArgs as0
  = case bimap (fmap fst) (fmap fst) $ partition ((==UN).snd) as0 of
      ([],[]) -> ZArgs
      ([],[i]) -> BArg1 i
      ([],[i,j]) -> BArg2 i j
      ([i],[]) -> UArg1 i
      ([i,j],[]) -> UArg2 i j
      ([i],[j]) -> DArg2 i j
      ([],bs) -> BArgN $ primArrayFromList bs
      (us,[]) -> UArgN $ primArrayFromList us
      -- TODO: handle ranges
      (us,bs) -> DArgN (primArrayFromList us) (primArrayFromList bs)

indent :: Int -> ShowS
indent ind = showString (replicate (ind*2) ' ')

prettyCombs
  :: (Comb, EnumMap Word64 Comb, Word64)
  -> ShowS
prettyCombs (c, es, w)
  = foldr (\(w,c) r -> prettyComb w c . showString "\n" . r)
      id (mapToList es)
  . showString "\n" . prettyComb w c

prettyComb :: Word64 -> Comb -> ShowS
prettyComb w (Lam ua ba _ _ s)
  = shows w . shows [ua,ba]
  . showString ":\n" . prettySection 2 s

prettySection :: Int -> Section -> ShowS
prettySection ind sec
  = indent ind . case sec of
      App _ r as ->
        showString "App "
          . showsPrec 12 r . showString " " . prettyArgs as
      Call _ i as ->
        showString "Call " . shows i . showString " " . prettyArgs as
      Jump i as ->
        showString "Jump " . shows i . showString " " . prettyArgs as
      Match i bs ->
        showString "Match " . shows i . showString "\n"
          . prettyBranches (ind+1) bs
      Yield as -> showString "Yield " . prettyArgs as
      Ins i nx ->
        prettyIns i . showString "\n" . prettySection ind nx
      Let s n ->
          showString "Let\n" . prettySection (ind+2) s
        . showString "\n" . prettySection ind n
      Die s -> showString $ "Die " ++ s
      Exit -> showString "Exit"

prettyBranches :: Int -> Branch -> ShowS
prettyBranches ind bs
  = case bs of
      Test1 i e df -> pdf df . picase i e
      Test2 i ei j ej df -> pdf df . picase i ei . picase j ej
      TestW df m ->
        pdf df . foldr (\(i,e) r -> picase i e . r) id (mapToList m)
      TestT df m ->
        pdf df . foldr (\(i,e) r -> ptcase i e . r) id (M.toList m)
  where
  pdf e = indent ind . showString "DFLT ->\n" . prettySection (ind+1) e
  ptcase t e
    = showString "\n" . indent ind . shows t . showString " ->\n"
    . prettySection (ind+1) e
  picase i e
    = showString "\n" . indent ind . shows i . showString " ->\n"
    . prettySection (ind+1) e

un :: ShowS
un = ('U':)

bx :: ShowS
bx = ('B':)

prettyIns :: Instr -> ShowS
prettyIns (Pack i as)
  = showString "Pack " . shows i . (' ':) . prettyArgs as
prettyIns i = shows i

prettyArgs :: Args -> ShowS
prettyArgs ZArgs = shows @[Int] []
prettyArgs (UArg1 i) = un . shows [i]
prettyArgs (BArg1 i) = bx . shows [i]
prettyArgs (UArg2 i j) = un . shows [i,j]
prettyArgs (BArg2 i j) = bx . shows [i,j]
prettyArgs (DArg2 i j) = un . shows [i] . (' ':) . bx . shows [j]
prettyArgs (UArgR i l) = un . shows (Prelude.take l [i..])
prettyArgs (BArgR i l) = bx . shows (Prelude.take l [i..])
prettyArgs (DArgR i l j k)
  = un . shows (Prelude.take l [i..]) . (' ':)
  . bx . shows (Prelude.take k [j..])
prettyArgs (UArgN v) = un . shows (primArrayToList v)
prettyArgs (BArgN v) = bx . shows (primArrayToList v)
prettyArgs (DArgN u b)
  = un . shows (primArrayToList u) . (' ':)
  . bx . shows (primArrayToList b)
prettyArgs (DArgV i j) = ('V':) . shows [i,j]
