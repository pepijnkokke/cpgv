{
module CP.Parser where

import Control.Monad.Error
import Control.Monad.State
import CP.Lexer
import CP.Syntax
}

%name proc Proc
%name prop Prop
%name tops Tops
%tokentype { Token }
%monad { StateT AlexState (Either String) }
%lexer { scan } { EOF }
%error { parseError }

%token
    ':'       { COLON }
    ';'       { SEMI }
    ','       { COMMA }
    '.'       { DOT }
    '/'       { SLASH }
    '('       { LPAREN }
    ')'       { RPAREN }
    '['       { LBRACK }
    ']'       { RBRACK }
    '{'       { LBRACE }
    '}'       { RBRACE }
    '|'       { BAR }
    '<->'     { LINK }
    'cut'     { CUT }
    'case'    { CASE }
    'roll'    { ROLL }
    'unr'     { UNROLL }
    '0'       { ZERO }
    '?'       { QUERY }
    '!'       { BANG }

    'forall'  { FORALL }
    'exists'  { EXISTS }
    'mu'      { MU }
    'nu'      { NU }
    '*'       { TIMES }
    '||'      { PAR }
    '+'       { PLUS }
    '&'       { WITH }
    '1'       { ONE }
    'bot'     { BOTTOM }
    '~'       { TILDE }

    'def'     { DEF }
    'type'    { TYPE }
    '|-'      { TURNSTILE }
    '='       { EQUALS }
    'check'   { CHECK }

    UIdent   { UIDENT $$ }
    LIdent   { LIDENT $$ }

%%

fst(p,q)     : p q                            { $1 }
snd(p,q)     : p q                            { $2 }
pair(p,q)    : p q                            { ($1, $2) }

revList(p)   : {- empty -}                    { [] }
             | revList(p) p                   { $2 : $1 }

list(p)      : revList(p)                     { reverse $1 }

sep(p,q)     : {- empty -}                    { [] }
             | sep1(p,q)                      { $1 }

sep1(p,q)    : p list(snd(q,p))               { $1 : $2 }

optSepDelim(p,q,l,r) : {- empty -}            { [] }
             | l sep(p,q) r                   { $2 }

labeledList(p,q) : sep(pair(p,snd(':',q)),',') { $1 }

Prop         :: { Prop }
             : 'exists' UIdent '.' Prop       { Exists $2 $4 }
             | 'forall' UIdent '.' Prop       { ForAll $2 $4 }
             | 'mu' UIdent '.' Prop           { Mu $2 $4 }
             | 'nu' UIdent '.' Prop           { Nu $2 $4 }
             | Prop1                          { $1 }

Prop1        :: { Prop }
             : Prop2 '*' Prop2                { Times $1 $3 }
             | Prop2 '||' Prop2               { Par $1 $3 }
             | '+' '{' labeledList(LIdent, Prop) '}' { Plus $3 }
             | '&' '{' labeledList(LIdent, Prop) '}' { With $3 }
             | Prop2                          { $1 }

Prop2        :: { Prop }
             : UIdent optSepDelim(Prop, ',', '(', ')')
                                              { Var $1 $2 }
             | '~' Prop2                      { Dual $2 }
             | '!' Prop2                      { OfCourse $2 }
             | '?' Prop2                      { WhyNot $2 }
             | '1'                            { One }
             | 'bot'                          { Bottom }
             | '(' Prop ')'                   { $2 }

Arg          :: { Arg }
             : LIdent                         { NameArg $1 }
             | Proc                           { ProcArg $1 }

Proc         :: { Proc }
             : UIdent optSepDelim(Arg, ',', '(', ')')
                                              { ProcVar $1 $2 }
             | LIdent '<->' LIdent            { Link $1 $3 }
             | 'cut' '[' LIdent ':' Prop ']' '(' Proc '|' Proc ')'
                                              { Cut $3 $5 $8 $10 }
             | LIdent '[' LIdent ']' '.' '(' Proc '|' Proc ')'
                                              { Out $1 $3 $7 $9 }
             | LIdent '(' LIdent ')' '.' Proc { In $1 $3 $6 }
             | LIdent '/' LIdent '.' Proc     { Select $1 $3 $5 }
             | 'case' LIdent '{' sep(pair(LIdent, snd(':', Proc)), ';') '}'
                                              { Case $2 $4 }
             | 'unr' LIdent '.' Proc          { Unroll $2 $4 }
             | 'roll' LIdent '[' LIdent ':' Prop ']' '(' Proc ',' Proc ')'
                                              { Roll $2 $4 $6 $9 $11 }
             | LIdent '[' Prop ']' '.' Proc   { SendProp $1 $3 $6 }
             | LIdent '(' UIdent ')' '.' Proc { ReceiveProp $1 $3 $6 }
             | LIdent '(' ')' '.' Proc        { EmptyIn $1 $5 }
             | LIdent '[' ']' '.' '0'         { EmptyOut $1 }
             | 'case' LIdent '(' sep(LIdent, ',') ')' '{' '}'
                                              { EmptyCase $2 $4 }
             | '!' LIdent '(' LIdent ')' '.' Proc
                                              { Replicate $2 $4 $7 }
             | '?' LIdent '[' LIdent ']' '.' Proc
                                              { Derelict $2 $4 $7 }
             | '?' optSepDelim(LIdent, ',', '(', ')')
                                              { Unk $2 }

Param        :: { Param }
             : LIdent                         { NameParam $1 }
             | UIdent                         { ProcParam $1 }

Defn         :: { Defn }
             : 'def' UIdent optSepDelim(Param, ',', '(', ')') '=' Proc '.'
                                              { ProcDef $2 $3 $5 }
             | 'type' UIdent optSepDelim(UIdent, ',', '(', ')') '=' Prop '.'
                                              { PropDef $2 $3 $5 }

Assertion    :: { Assertion }
             : 'check' Assertion1             { $2 True }
             | Assertion1                     { $1 False }

Assertion1   :: { Bool -> Assertion }
             : Proc '|-' sep1(pair(LIdent,snd(':', Prop)),',') '.'
                                              { Assert $1 $3 }

Top          :: { Either Defn Assertion}
             : Defn                           { Left $1 }
             | Assertion                      { Right $1 }

Tops         :: { [Either Defn Assertion] }
             : list(Top)                      { $1 }

{

parseError _ = do AlexPn _ line col <- gets alex_pos
                  throwError ("Parse error at line " ++ show line ++ ", column " ++ show col)


scan cont = do s <- get
               case unAlex alexMonadScan s of
                 Left err -> let AlexPn _ line col = alex_pos s
                             in  throwError ("Lexer error at line " ++ show line ++ ", column " ++ show col)
                 Right (s', t) -> put s' >> cont t

lexInit s = AlexState { alex_pos = alexStartPos,
                        alex_inp = s,
                        alex_chr = '\n',
                        alex_bytes = [],
                        alex_scd = 0 }

parse p s = evalStateT p (lexInit s)

}