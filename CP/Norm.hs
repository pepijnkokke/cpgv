{-# LANGUAGE FlexibleInstances, TupleSections, PatternGuards #-}
module CP.Norm where

import Prelude hiding ((<$>))
import Control.Monad.Except
import CP.Check
import CP.Expand (expandP)
import Data.List (intercalate, tails)
import CP.Syntax
import CP.Printer
import Text.PrettyPrint.Leijen

import CP.Trace
import CP.Utilities
import Data.IORef
import System.IO.Unsafe

showCP c = displayS (renderPretty 0.8 120 (pretty c)) ""
{-# NOINLINE doCheckSteps #-}
doCheckSteps = unsafePerformIO (newIORef False)
checkSteps   = unsafePerformIO (readIORef doCheckSteps)

--------------------------------------------------------------------------------
-- Operators (types with holes)

type Op = (String, Prop)

appl :: Op -> Prop -> Prop
appl (x, b) a = inst x a b

dualOp :: Op -> Op
dualOp (x, b) = (x, dual (appl (x, b) (Neg x)))

data Fragment = Fragment [(String, Prop)] Proc
cutVars (Fragment zs p) = map fst zs

instance Pretty Fragment
    where pretty (Fragment zs p) = group (hang 2 (text "<" <> cat (punctuate (comma <> space) [text z <> colon <+> pretty a | (z,a) <- zs]) <> text ">" <$> pretty p))

ms <++> ns = liftM2 (++) ms ns

class Fragments t
    where addVar :: String -> Prop -> t -> M [Fragment]

instance Fragments [Fragment]
    where addVar v a fs = concat `fmap` mapM add fs
              where add (Fragment vs p)
                        | v `elem` fn p = fragment ((v, a) : vs') p
                        | otherwise     = fragment vs p
                        where vs' = filter ((v /=) . fst) vs

instance Fragments (M [Fragment])
    where addVar v a mfs = addVar v a =<< mfs

renameBoundVariable :: String -> Proc -> String -> Proc -> M (String, Proc, Proc)
renameBoundVariable x p x' p'=
    do n <- fresh x
       liftM2 (n,,) (replace x n p) (replace x' n p')

traceCutReduction x a = trace ("Reducing cut on " ++ showCP x ++ " of type " ++ showCP a)

stepPrincipal :: Behavior -> Fragment -> Fragment -> M [Fragment]
stepPrincipal _ (Fragment zs (Link x y)) (Fragment zs' p)
    | x `elem` map fst zs', Just a <- lookup x zs, not (isWhyNot a) =
        traceCutReduction x a $
        do p' <- replace x y p
           fragment (add y zs') p'
    | y `elem` map fst zs', Just a <- lookup y zs, not (isWhyNot a) =
        traceCutReduction y a $
        do p' <- replace y x p
           fragment (add x zs') p'
    where isWhyNot WhyNot{} = True
          isWhyNot _        = False
          add z = case lookup z zs of
                    Nothing -> id
                    Just a  -> ((z, a) :)
stepPrincipal _ (Fragment zs (Out x y p q)) (Fragment zs' (In x' y' r))
    | x == x', Just (a `Times` b) <- lookup x zs =
        traceCutReduction x (a `Times` b) $
        do (y'', p', r') <- renameBoundVariable y p y' r
           addVar y'' a (fragment zs p') <++>
               addVar y'' (dual a) (addVar x b (fragment zs q)) <++>
               addVar y'' (dual a) (addVar x (dual b) (fragment zs' r'))
stepPrincipal _ (Fragment zs (Select x l p)) (Fragment zs' (Case x' bs))
    | x == x', Just (Plus bts) <- lookup x zs, Just q <- lookup l bs, Just a <- lookup l bts =
        traceCutReduction x (Plus bts) $
        addVar x a (fragment zs p) <++>
        addVar x (dual a) (fragment zs' q)
stepPrincipal _ (Fragment zs (SendProp x a p)) (Fragment zs' (ReceiveProp x' t' q))
    | x == x', Just (Exist t b) <- lookup x zs, t == t' =
        traceCutReduction x (Exist t b) $
        addVar x (inst t a b) (fragment [(z,inst t a c) | (z,c) <- zs] p) <++>
        addVar x (dual (inst t a b)) (fragment [(z,inst t a c) | (z,c) <- zs'] (inst t a q))
stepPrincipal _ (Fragment zs (SendTerm x m p)) (Fragment zs' (ReceiveTerm x' i q))
    | x == x', Just (FOExist t b) <- lookup x zs =
        traceCutReduction x (FOExist t b) $
        addVar x b (fragment zs p) <++>
        addVar x (dual b) (fragment zs' (instProc i (reduce m) q))
stepPrincipal _ (Fragment zs (EmptyOut x)) (Fragment zs' (EmptyIn x' p))
    | x == x', Just One <- lookup x zs =
        traceCutReduction x (Just One) $
        fragment (filter ((x' /=) . fst) zs') p
stepPrincipal globals (Fragment zs (Rec x p)) (Fragment zs' (CoRec x' y q))
    | x == x', Just (Mu t b) <- lookup x zs, Just aperp <- lookup y (zs' ++ globals) =
        traceCutReduction x (Mu t b) $
        let f = (t, b)
            fperp = dualOp f
            a = dual aperp
            nu (t, a) = Nu t a
            mu (t, a) = Mu t a
        in  do z <- fresh "z"
               q' <- replace x z q
               q'' <- replace y z q
               recurse <- funct f z x (CoRec x z q'')
               addVar z (fperp `appl` a) (fragment zs' q') <++>
                   addVar x (f `appl` mu f) (fragment zs p) <++>
                   addVar x (fperp `appl` nu fperp) (addVar z (f `appl` aperp) (fragment zs' recurse))
    | x == x', Just (Mu t b) <- lookup x zs =
        trace (unlines ["Unable to reduce rec/corec cut:",
                        unlines (map ("    " ++) (lines (showCP (Fragment zs (Rec x p))))),
                        unlines (map ("    " ++) (lines (showCP (Fragment zs' (CoRec x' y q))))),
                        "as we are missing a binding for " ++ y])
              (return [])
    where -- assuming that there are propositions A and B such that q |- x:A,w:B,
          -- funct c x w q |- x:c A,w:cbar B
          funct (t,c) x w q
              | t `notElem` fpv c = return (Link x w)
          funct (t, Var t' []) x w q
              | t == t' = return q
          funct (t, c1 `Times` c2) x w q =
              do y <- fresh "y"
                 z <- fresh "z"
                 q' <- replace x y =<< replace w z q
                 left <- funct (t, c1) y z q'
                 right <- funct (t, c2) x w q
                 return (In w z (Out x y left right))
          funct (t, c1 `Par` c2) x w q =
              do y <- fresh "y"
                 z <- fresh "z"
                 q' <- replace x y =<< replace w z q
                 left <- funct (t, c1) y z q'
                 right <- funct (t, c2) x w q
                 return (In x y (Out w z left right))
          funct (t, Plus lts) x w q = Case w `fmap` mapM branch lts
              where branch (l, c) = ((l,) . Select x l) `fmap` funct (t, c) x w q
          funct (t, With lts) x w q = Case x `fmap` mapM branch lts
              where branch (l, c) = ((l,) . Select w l) `fmap` funct (t, c) x w q
          funct (t, FOExist _ c) x w q = do m <- fresh "m"
                                            (ReceiveTerm w m . SendTerm x (EVar m)) `fmap` funct (t, c) x w q
          funct (t, FOUniv _ c) x w q = do m <- fresh "m"
                                           (ReceiveTerm x m . SendTerm w (EVar m)) `fmap` funct (t, c) x w q
          funct (t, a) _ _ _ = error ("Unimplemented: functoriality for " ++ t ++ "." ++ show (pretty a))

stepPrincipal _ (Fragment zs (Replicate x y p)) (Fragment zs' (Derelict x' y' q))
    | x == x', Just (OfCourse a) <- lookup x zs =
        traceCutReduction x (OfCourse a) $
        do (y'', p', q') <- renameBoundVariable y p y' q
           return [Fragment zs (Replicate x y p)] <++>
               addVar y'' a (fragment zs p') <++>
               addVar y'' (dual a) (fragment zs' q')
stepPrincipal _ _ _ = return []

fragment :: [(String, Prop)] -> Proc -> M [Fragment]
fragment zs (Quote m (Just ds)) = let EQuote p _ = reduce m
                                  in  fragment zs =<< expandP ds p
fragment zs (Cut x a p q) = do x' <- fresh x
                               (fragment ((x', a) : zs) =<< replace x x' p) <++>
                                 (fragment ((x', dual a) : zs) =<< replace x x' q)
fragment zs p             = return [Fragment (filter ((`elem` vs) . fst) zs) p]
    where vs = fn p

unfragment :: [Fragment] -> Proc
unfragment fs = case binderClash p of
                  Nothing -> p
                  Just b  -> trace ("Binder " ++ b ++ " not fresh!") p
    where p = loop (filter (not . weaken) fs) []

          weaken (Fragment _ p@(Replicate x _ _)) = and [x `notElem` map fst zs' | Fragment zs' p' <- fs, p /= p']
          weaken _                              = False

          loop [Fragment [] p] [] = p
          loop (Fragment [(x,a)] p : rest) passed = trace ("Introducing cut on " ++ x) $
                                                    Cut x a p (loop (map filterX (rest ++ passed)) [])
              where filterX (Fragment zs q) = let f = Fragment (filter ((x /=) . fst) zs) q
                                              in  {- trace (unlines ["Filtered " ++ x ++ " from fragment", showCP (Fragment zs q), "Giving", showCP f]) -} f
          loop (f : rest) passed = loop rest (f : passed)
          loop [] passed = error (unlines ("Failed in unfragment! Remaining fragments were:" : map (showCP . pretty) passed))

commute :: Behavior -> [Fragment] -> (Behavior -> [Fragment] -> M Proc) -> (Behavior -> [Fragment] -> M Proc) -> M Proc
commute bs fs f g = loop bs fs [] False
    where loop bs pending passed = trace (unlines ("Commute pending" : map showCP pending ++ "Commute passed": map showCP passed)) (loop' bs pending passed)

          loop' :: Behavior -> [Fragment] -> [Fragment] -> Bool -> M Proc
          loop' bs [] passed True = f bs passed
          loop' bs [] passed False = g bs passed
          loop' bs (f@(Fragment zs (Out x y p q)) : rest) passed b
              | x `notElem` map fst zs, Just (t `Times` u) <- lookup x bs =
                  trace (x ++ '[' : y ++ "]") $
                  do pfs <- fragment zs p
                     qfs <- fragment zs q
                     let pns = concatMap cutVars pfs
                         qns = concatMap cutVars qfs
                         pzs = filter (`elem` pns) (map fst zs)
                         qzs = filter (`elem` qns) (map fst zs)
                         (ps, qs, rest') = part pfs pzs qfs qzs [] (rest ++ passed) [] False
                     if null ps && null qs
                     then loop bs rest (f : passed) b
                     else trace ("Partitioned into:\n\n" ++
                                 "(" ++ intercalate "," (map show pns) ++ ")\n" ++
                                 unlines (map showCP ps) ++
                                 "\n\nand\n\n" ++
                                 "(" ++ intercalate "," (map show qns) ++ ")\n" ++
                                 unlines (map showCP qs)) $
                          do p' <- loop ((x,u) : (y,t) : bs ++ zs) ps [] True
                             q' <- loop ((x,u) : (y,t) : bs ++ zs) qs [] True
                             if null rest'
                             then return (Out x y p' q')
                             else do fs <- fragment zs (Out x y p' q')
                                     loop bs rest' fs (p /= p' || q /= q')
              where part ps pzs qs qzs ss rest passed b =
                        trace ("Partitioning into:\n\n" ++
                               "(" ++ intercalate "," (map show pzs) ++ ")\n" ++
                               unlines (map showCP ps) ++
                               "\n\nand\n\n" ++
                               "(" ++ intercalate "," (map show qzs) ++ ")\n" ++
                               unlines (map showCP qs)) $
                        part' ps pzs qs qzs ss rest passed b

                    part' ps pzs qs qzs ss [] passed False
                        | null passed = (ps' ++ ss, qs' ++ ss, [])
                        | otherwise   = (ps' ++ ss, qs' ++ ss, passed ++ ss)
                        where pvs = concat [map fst vs | Fragment vs p <- passed]
                              ps' = [Fragment (filter ((`notElem` pvs) . fst) vs) p | Fragment vs p <- ps]
                              qs' = [Fragment (filter ((`notElem` pvs) . fst) vs) q | Fragment vs q <- qs]
                    part' ps pzs qs qzs ss [] passed True = part ps pzs qs qzs ss passed [] False
                    part' ps pzs qs qzs ss (Fragment zs (Replicate x y p) : rs) passed b = part ps pzs qs qzs (Fragment zs (Replicate x y p) : ss) rs passed b
                    part' ps pzs qs qzs ss (Fragment zs r:rs) passed b
                        | any (`elem` pzs) (map fst zs) && all (`notElem` qzs) (map fst zs) = part (Fragment zs r : ps) (map fst zs ++ pzs) qs qzs ss rs passed True
                        | any (`elem` qzs) (map fst zs) && all (`notElem` pzs) (map fst zs) = part ps pzs (Fragment zs r : qs) (map fst zs ++ qzs) ss rs passed True
                        | otherwise = part ps pzs qs qzs ss rs (Fragment zs r : passed) b
          loop' bs (Fragment zs (In x y p) : rest) passed _
              | x `notElem` map fst zs, Just (t `Par` u) <- lookup x bs =
                  trace (x ++ '(' : y ++ ")") $
                  do fs <- fragment zs p
                     In x y `fmap` loop ((x,u) : (y,t) : bs ++ zs) (fs ++ rest) passed True
          loop' bs (Fragment zs (Select x l p) : rest) passed _
              | x `notElem` map fst zs, Just (Plus ts) <- lookup x bs, Just t <- lookup l ts =
                  trace (x ++ '/' : l) $
                  do fs <- fragment zs p
                     Select x l `fmap` loop ((x,t) : bs ++ zs) (fs ++ rest) passed True
          loop' behavior (Fragment zs (Case x bs) : rest) passed _
              | x `notElem` map fst zs, Just (With ts) <- lookup x behavior =
                  trace ("case " ++ x) $
                  Case x `fmap` sequence [do fs <- fragment zs p
                                             let Just t = lookup l ts
                                             (l,) `fmap` commute ((x,t) : behavior ++ zs) (fs ++ rest ++ passed) f g
                                          | (l,p) <- bs]
          loop' bs (Fragment zs (Rec x p) : rest) passed _
              | x `notElem` map fst zs, Just (Mu y t) <- lookup x bs =
                  trace ("unr " ++ x) $
                  do fs <- fragment zs p
                     Rec x `fmap` loop ((x, inst y (Mu y t) t) : bs ++ zs) (fs ++ rest) passed True
          loop' bs (Fragment zs (Replicate x y p) : rest) passed _
              | x `notElem` map fst zs, Just (OfCourse t) <- lookup x bs,
                and [all (isWhyNot . snd) zs' | Fragment zs' _ <- rest ++ passed] =
                   trace ('!' : x ++ '(' : y ++ ")") $
                   do fs <- fragment zs p
                      Replicate x y `fmap` loop ((x, t) : bs ++ zs) (fs ++ rest) passed True
              where isWhyNot (WhyNot _) = True
                    isWhyNot _          = False
          loop' bs (Fragment zs (Derelict x y p) : rest) passed _
              | x `notElem` map fst zs, Just (WhyNot t) <- lookup x bs =
                  trace ('?' : x ++ '[' : y ++ "]") $
                  do fs <- fragment zs p
                     Derelict x y `fmap` loop ((x,t) : bs ++ zs) (fs ++ rest) passed True
          loop' bs (Fragment zs (SendProp x a p) : rest) passed _
              | x `notElem` map fst zs, Just (Exist _ t) <- lookup x bs =
                  trace (x ++ "[" ++ show (pretty a) ++ "]") $
                  do fs <- fragment zs p
                     SendProp x a `fmap` loop ((x,t) : zs ++ bs) (fs ++ rest) passed True
          loop' bs (Fragment zs (ReceiveProp x t p) : rest) passed _
              | x `notElem` map fst zs, Just (Univ _ u) <- lookup x bs =
                  trace (x ++ "(" ++ showCP t ++ ")") $
                  do fs <- fragment zs p
                     ReceiveProp x t `fmap` loop ((x,u) : bs ++ zs) (fs ++ rest) passed True
          loop' bs (Fragment zs (SendTerm x m p) : rest) passed _
              | x `notElem` map fst zs, Just (FOExist _ t) <- lookup x bs =
                  trace (x ++ "*[" ++ show (pretty m) ++ "]") $
                  do fs <- fragment zs p
                     SendTerm x m `fmap` loop ((x, t) : zs ++ bs) (fs ++ rest) passed True
          loop' bs (Fragment zs (ReceiveTerm x y p) : rest) passed _
              | x `notElem` map fst zs, Just (FOUniv _ t) <- lookup x bs =
                  trace (x ++ "*(" ++ y ++ ")") $
                  do fs <- fragment zs p
                     ReceiveTerm x y `fmap` loop ((x,t) : bs ++ zs) (fs ++ rest) passed True
          loop' bs (f@(Fragment zs (EmptyIn x p)) : rest) passed _
              | x `notElem` map fst zs = trace (x ++ "()") $
                                         do fs <- fragment zs p
                                            EmptyIn x `fmap` loop bs (fs ++ rest) passed True
          loop' bs (Fragment zs (Quote m (Just ds)) : rest) passed _ =
              let EQuote p _ = reduce m
              in  do pfs <- fragment zs =<< expandP ds p
                     loop bs (pfs ++ rest) passed True
          loop' bs (f : rest) passed b = loop bs rest (f : passed) b

normalize :: Proc -> Behavior -> M (Proc, Proc)
normalize p b =
    trace ("Normalizing " ++ showCP p) $
    do fs <- fragment [] p
       let is = [1..length fs]
           wl = makeWorkList is []
       fs' <- loop b wl (zip is fs) (length fs + 1)
       executed <- commute b fs' (const (return . unfragment)) (const (return . unfragment))
       simplified <- commute b fs' recurse (const (return . unfragment))
       return (executed, simplified)
    where recurse b fs = trace (unlines ("Recursing on" : map showCP fs)) $
                         do fs' <- loop b (makeWorkList is []) (zip is fs) (length fs + 1)
                            commute b fs' recurse (const (return . unfragment))
              where is = [1..length fs]

          makeWorkList is js = [(i, i') | (i:is') <- tails is, i' <- is'] ++ [(i,j) | i <- is, j <- js]


          loop b [] ifs _ = trace (unlines ("Done!" : map showCP  (map snd ifs))) $
                            return (map snd ifs)
          loop b ((i,j):wl) ifs k
              | Just fi <- lookup i ifs, Just fj <- lookup j ifs =
                  do fs' <- step b fi fj
                     case fs' of
                       [] -> loop b wl ifs k
                       _  -> let ks = [k..k + length fs' - 1]
                                 k' = k + length fs'
                                 notIorJ k = i /= k && j /= k
                                 ifs' = zip ks fs' ++ filter (notIorJ . fst) ifs
                                 wl'  = makeWorkList ks (filter notIorJ (map fst ifs)) ++
                                        [(i',j') | (i',j') <- wl, notIorJ i', notIorJ j']
                             in  trace (unlines (["Reduced fragments"] ++ map showCP [fi, fj] ++ ["to"] ++ map showCP fs')) $
                                 trace (replicate 120 '-' ++ '\n' :
                                        showCP (unfragment (map snd ifs'))) $
                                 if checkSteps
                                 then checkFragments b fi fj fs' $ loop b wl' ifs' k'
                                 else loop b wl' ifs' k'
              | otherwise = error "Missing fragments in loop"

          step b fi fj =
              do fs <- stepPrincipal b fi fj
                 case fs of
                   [] -> stepPrincipal b fj fi
                   _  -> return fs

checkFragments _ _ _ [] s = s
checkFragments b fi fj (Fragment vs p : fs) s =
    case r of
      Left err -> error ("Normalization broke: given behavior\n" ++
                         unlines (map ("    " ++) (lines (showCP b))) ++
                         "and input fragments\n" ++
                         unlines (map ("    " ++) (lines (showCP fi))) ++
                         "and\n" ++
                         unlines (map ("    " ++) (lines (showCP fj))) ++
                         "produced fragment\n" ++
                         unlines (map ("    " ++) (lines (showCP (Fragment vs p)))) ++
                         "with error\n" ++
                         err)
      _ -> checkFragments b fi fj fs s
    where (_, r) = runCheck (check' p) (vs ++ b, [])

----------------------------------------------------------------------------------------------------

instProc i m (ProcVar x args) = ProcVar x (map instArg args)
    where instArg (ProcArg p) = ProcArg (instProc i m p)
          instArg (NameArg x) = NameArg x
instProc i m (Cut x a p q) = Cut x a (instProc i m p) (instProc i m q)
instProc i m (In x y p) = In x y (instProc i m p)
instProc i m (Out x y p q) = Out x y (instProc i m p) (instProc i m q)
instProc i m (Select x l p) = Select x l (instProc i m p)
instProc i m (Case x bs) = Case x [(l, instProc i m p) | (l, p) <- bs]
instProc i m (Rec x p) = Rec x (instProc i m p)
instProc i m (CoRec x y p) = CoRec x y (instProc i m p)
instProc i m (Replicate x y p) = Replicate x y (instProc i m p)
instProc i m (Derelict x y p) = Derelict x y (instProc i m p)
instProc i m (SendProp x a p) = SendProp x a (instProc i m p)
instProc i m (ReceiveProp x y p) = ReceiveProp x y (instProc i m p)
instProc i m (SendTerm x n p) = SendTerm x (reduce (instTerm i m n)) (instProc i m p)
instProc i m (ReceiveTerm x j p)
    | i == j = ReceiveTerm x j p
    | otherwise = ReceiveTerm x j (instProc i m p)
instProc i m (EmptyIn x p) = EmptyIn x (instProc i m p)
instProc i m (Quote n ds) = Quote (instTerm i m n) ds
instProc _ _ p = p

instTerm i m (EApp n n') = EApp (instTerm i m n) (instTerm i m n')
instTerm i m (ELam j t n)
    | i == j = ELam j t n
    | otherwise = ELam j t (instTerm i m n)
instTerm i m (EVar j)
    | i == j = m
    | otherwise = EVar j
instTerm i m (EQuote p b) = EQuote (instProc i m p) b
instTerm i m (EIf n0 n1 n2) = EIf (instTerm i m n0) (instTerm i m n1) (instTerm i m n2)
instTerm i m (EFix n) = EFix (instTerm i m n)
instTerm _ _ n = n

reduce (EApp e f) =
    case (e', f') of
      (EApp (EVar "+") (EInt i), EInt j) -> EInt (i + j)
      (EApp (EVar "*") (EInt i), EInt j) -> EInt (i * j)
      (EVar "isZero", EInt i) -> EBool (i == 0)
      (ELam x t m, n) -> reduce (instTerm x n m)
      _ -> EApp e' f'
    where e' = reduce e
          f' = reduce f
reduce (EIf m n o) = if reduce m == EBool True then reduce n else reduce o
reduce (EFix m) =
    case reduce m of
      ELam x t n -> reduce (instTerm x (EFix (ELam x t n)) n)
reduce m = m
