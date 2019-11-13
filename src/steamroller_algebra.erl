%%
%% @doc An implementation of ["Strictly Pretty" (2000) by Christian Lindig][0].
%%
%% Inspired by the Elixir implementation of the same paper in Inspect.Algebra. Thanks to the core team for their hard work!
%%
%% [0] https://citeseerx.ist.psu.edu/viewdoc/summary?doi=10.1.1.34.2200
%%
-module(steamroller_algebra).

-export([format_tokens/1, format_tokens/2, generate_doc/1, pretty/1, pretty/2]).
% Testing
-export([repeat/2, from_the_paper/2]).

-type doc() :: doc_nil
            | {doc_cons, doc(), doc()}
            | {doc_text, binary()}
            | {doc_nest, integer(), doc()}
            | {doc_break, binary()}
            | {doc_group, doc(), inherit()}
            | {doc_force_break, doc()}.

-type sdoc() :: s_nil | {s_text, binary(), sdoc()} | {s_line, binary(), sdoc()}.
-type mode() :: flat | break.
-type inherit() :: self | inherit.
-type continue() :: continue | done.
-type force_break() :: force_break | no_force_break.
-type token() :: steamroller_ast:token().
-type tokens() :: steamroller_ast:tokens().
-type previous_term() :: new_file | attribute | spec | list | function | comment.

-define(sp, <<" ">>).
-define(nl, <<"\n">>).
-define(two_nl, <<"\n\n">>).
-define(dot, <<".">>).
-define(max_width, 100).
-define(indent, 4).

-define(IS_LIST_CHAR(C), (C == '(' orelse C == '{' orelse C == '[' orelse C == '<<')).
-define(IS_OPERATOR(C), (C == '+' orelse C == '-' orelse C == '*' orelse C == '/' orelse C == 'div')).

%% API

-spec format_tokens(tokens()) -> binary().
format_tokens(Tokens) -> format_tokens(Tokens, ?max_width).

-spec format_tokens(tokens(), integer()) -> binary().
format_tokens(Tokens, Width) ->
    Doc = generate_doc(Tokens),
    pretty(Doc, Width).

-spec generate_doc(tokens()) -> doc().
generate_doc(Tokens) -> generate_doc_(Tokens, empty(), new_file).

-spec pretty(doc()) -> binary().
pretty(Doc) -> pretty(Doc, ?max_width).

-spec pretty(doc(), integer()) -> binary().
pretty(Doc, Width) ->
    SDoc = format(Width, 0, [{0, flat, group(Doc)}]),
    String = sdoc_to_string(SDoc),
    <<String/binary, "\n">>.

% Used for testing.
-spec from_the_paper(integer(), integer()) -> binary().
from_the_paper(Width, Indent) ->
    C = test_binop(<<"a">>, <<"==">>, <<"b">>, Indent),
    E1 = test_binop(<<"a">>, <<"<<">>, <<"2">>, Indent),
    E2 = test_binop(<<"a">>, <<"+">>, <<"b">>, Indent),
    Doc = test_ifthen(C, E1, E2, Indent),
    pretty(Doc, Width).

%% Constructor Functions

-spec cons(doc(), doc()) -> doc().
cons(X, Y) -> {doc_cons, X, Y}.

-spec cons(list(doc())) -> doc().
cons([X]) -> X;
cons([X, Y]) -> cons(X, Y);
cons([X | Rest]) -> cons(X, cons(Rest)).

-spec empty() -> doc().
empty() -> doc_nil.

-spec text(binary()) -> doc().
text(S) -> {doc_text, S}.

-spec nest(integer(), doc()) -> doc().
nest(I, X) -> {doc_nest, I, X}.

-spec break(binary()) -> doc().
break(S) -> {doc_break, S}.

-spec force_break(force_break(), doc()) -> doc().
force_break(force_break, X) -> {doc_force_break, X};
force_break(no_force_break, X) -> X.

-spec group(doc()) -> doc().
group(D) -> {doc_group, D, self}.

% Group inheritance is lifted from the Elixir algebra implementation.
-spec group(doc(), inherit()) -> doc().
group(D, Inherit) -> {doc_group, D, Inherit}.

%% Operators

-spec space(doc(), doc()) -> doc().
space(X, Y) -> concat(X, Y, ?sp).

-spec space(list(doc())) -> doc().
space([X]) -> X;
space([X, Y]) -> space(X, Y);
space([X | Rest]) -> space(X, space(Rest)).

-spec stick(doc(), doc()) -> doc().
stick(X, Y) -> concat(X, Y, <<>>).

-spec newline(doc(), doc()) -> doc().
newline(X, Y) -> concat(X, Y, ?nl).

-spec newline(list(doc())) -> doc().
newline([X]) -> X;
newline([X, Y]) -> newline(X, Y);
newline([X | Rest]) -> newline(X, newline(Rest)).

-spec newlines(doc(), doc()) -> doc().
newlines(X, Y) -> concat(X, Y, ?two_nl).

-spec concat(doc(), doc(), binary()) -> doc().
concat(doc_nil, Y, _) -> Y;
concat(X, doc_nil, _) -> X;
concat(X, Y, Break) -> cons(X, cons(break(Break), Y)).

%% Token Consumption

-spec generate_doc_(tokens(), doc(), previous_term()) -> doc().
generate_doc_([], Doc, _) -> Doc;
generate_doc_([{'-', _} = H0, {atom, _, spec} = H1, {'(', _} | Rest0], Doc, PrevTerm) ->
    % Remove brackets from Specs
    Rest1 = remove_matching('(', ')', Rest0),
    generate_doc_([H0, H1 | Rest1], Doc, PrevTerm);
generate_doc_([{'-', _}, {atom, _, spec} | Tokens], Doc, _PrevTerm) ->
    % Spec
    % Re-use the function code because the syntax is identical.
    {Group, Rest} = function(Tokens),
    Spec = cons(text(<<"-spec ">>), Group),
    generate_doc_(Rest, newlines(Doc, Spec), spec);
generate_doc_([{'-', _}, {atom, _, Atom} | Tokens], Doc, _PrevTerm) ->
    % Module Attribute
    {Group, Rest} = attribute(Atom, Tokens),
    % Put a line gap between module attributes.
    generate_doc_(Rest, newlines(Doc, Group), attribute);
generate_doc_([{atom, _, _Atom} | _] = Tokens, Doc0, PrevTerm) ->
    % Function
    {Group, Rest} = function(Tokens),
    Doc1 =
        case PrevTerm of
            PrevTerm when PrevTerm == comment orelse PrevTerm == spec ->
                newline(Doc0, Group);
            _ ->
                newlines(Doc0, Group)
        end,
    generate_doc_(Rest, Doc1, function);
generate_doc_([{C, _} | _] = Tokens, Doc, _PrevTerm) when ?IS_LIST_CHAR(C) ->
    % List -> if this is at the top level this is probably a config file
    {ForceBreak, Group, Rest} = list_group(Tokens),
    generate_doc_(Rest, cons(Doc, force_break(ForceBreak, Group)), list);
generate_doc_([{comment, _, CommentText} | Rest], Doc0, PrevTerm) ->
    % Comment
    Comment = comment(CommentText),
    Doc1 =
        case PrevTerm of
            new_file -> cons(Doc0, Comment);
            comment -> newline(Doc0, Comment);
            _ -> newlines(Doc0, Comment)
        end,
    generate_doc_(Rest, Doc1, comment).

%% Erlang Source Elements

-spec attribute(atom(), tokens()) -> {doc(), tokens()}.
attribute(Att, Tokens) ->
    {_ForceBreak, Expr, [{dot, _} | Rest]} = list_group(Tokens),
    Attribute =
          group(
            cons(
              [
               text(<<"-">>),
               text(a2b(Att)),
               Expr,
               text(?dot)
              ]
             )
           ),
    {Attribute, Rest}.

-spec function(tokens()) -> {doc(), tokens()}.
function(Tokens) ->
    {Clauses, Rest} = clauses(Tokens),
    {group(newline(Clauses)), Rest}.

-spec list_group(tokens()) -> {force_break(), doc(), tokens()}.
list_group([{'(', _} | Rest0]) ->
    {Tokens, Rest1, _} = get_until('(', ')', Rest0),
    {ForceBreak, ListGroup} = brackets(Tokens, <<"(">>, <<")">>),
    {ForceBreak, ListGroup, Rest1};
list_group([{'{', _} | Rest0]) ->
    {Tokens, Rest1, _} = get_until('{', '}', Rest0),
    {ForceBreak, ListGroup} = brackets(Tokens, <<"{">>, <<"}">>),
    {ForceBreak, ListGroup, Rest1};
list_group([{'[', _} | Rest0]) ->
    {Tokens, Rest1, _} = get_until('[', ']', Rest0),
    {ForceBreak, ListGroup} = brackets(Tokens, <<"[">>, <<"]">>),
    {ForceBreak, ListGroup, Rest1};
list_group([{'<<', _} | Rest0]) ->
    {Tokens, Rest1, _} = get_until('<<', '>>', Rest0),
    {ForceBreak, ListGroup} = brackets(Tokens, <<"<<">>, <<">>">>),
    {ForceBreak, ListGroup, Rest1}.

-spec brackets(tokens(), binary(), binary()) -> {force_break, doc()}.
brackets([], Open, Close) ->
    {no_force_break, group(cons(text(Open), text(Close)))};
brackets(Tokens, Open, Close) ->
    {ForceBreak, ListElements} = list_elements(Tokens),

    Doc =
        group(
          force_break(
            ForceBreak,
            stick(
              nest(
                ?indent,
                stick(
                  text(Open),
                  space(
                    ListElements
                   )
                 )
               ),
              text(Close)
             )
           )
         ),
    {ForceBreak, Doc}.

-spec list_elements(tokens()) -> {force_break(), list(doc())}.
list_elements(Tokens) -> list_elements(Tokens, [], no_force_break).

-spec list_elements(tokens(), list(doc()), force_break()) -> {force_break(), list(doc())}.
list_elements([], Acc, ForceBreak) -> {ForceBreak, lists:reverse(Acc)};
list_elements([{C, _} | _] = Tokens, Acc, ForceBreak0) when ?IS_LIST_CHAR(C) ->
    {ListGroupForceBreak, Group, Rest} = list_group(Tokens),
    ForceBreak1 = resolve_force_break([ForceBreak0, ListGroupForceBreak]),
    list_elements(Rest, [Group | Acc], ForceBreak1);
list_elements(Tokens, Acc, ForceBreak0) ->
    {_End, ForceBreak1, Expr, Rest} = expr(Tokens, ForceBreak0),
    list_elements(Rest, [Expr | Acc], ForceBreak1).

-spec clauses(tokens()) -> {list(doc()), tokens()}.
clauses(Tokens) -> clauses(Tokens, []).

-spec clauses(tokens(), list(doc())) -> {list(doc()), tokens()}.
clauses(Tokens, Acc0) ->
    {Continue, Clause, Rest0} = function_head_and_clause(Tokens),
    Acc1 = [Clause | Acc0],
    case Continue of
        continue -> clauses(Rest0, Acc1);
        done -> {lists:reverse(Acc1), Rest0}
    end.

-spec function_head_and_clause(tokens()) -> {continue(), doc(), tokens()}.
function_head_and_clause(Tokens) -> function_head_and_clause(Tokens, empty()).

-spec function_head_and_clause(tokens(), doc()) -> {continue(), doc(), tokens()}.
function_head_and_clause([{atom, _, Name} | Rest], Doc) ->
    % Name
    function_head_and_clause(Rest, cons(Doc, text(a2b(Name))));
function_head_and_clause([{C, _} | _] = Tokens, Doc) when ?IS_LIST_CHAR(C) ->
    % Args
    {_ForceBreak, Group, Rest} = list_group(Tokens),
    function_head_and_clause(Rest, cons(Doc, Group));
function_head_and_clause([{'->', _} | Rest0], Doc) ->
    % End
    {Continue, ForceBreak, Body, Rest1} = clause(Rest0),
    {Continue, cons(Doc, force_break(ForceBreak, nest(?indent, group(space(text(<<" ->">>), Body), inherit)))), Rest1}.

-spec clause(tokens()) -> {continue(), force_break(), doc(), tokens()}.
clause(Tokens) ->
    {End, ForceBreak, Exprs, Rest} = exprs(Tokens),
    Continue = case End of dot -> done; ';' -> continue end,
    if length(Exprs) > 1 ->
           % Force indentation for multi-line clauses
           {Continue, force_break, space(Exprs), Rest};
       true ->
           [Expr] = Exprs,
           {Continue, ForceBreak, Expr, Rest}
    end.

-spec exprs(tokens()) -> {dot | ';', force_break(), list(doc()), tokens()}.
exprs(Tokens) -> exprs(Tokens, [], no_force_break).

-spec exprs(tokens(), list(doc()), force_break()) -> {dot | ';', force_break(), list(doc()), tokens()}.
exprs(Tokens, Acc0, ForceBreak0) ->
    {End, ForceBreak1, Expr, Rest} = expr(Tokens, ForceBreak0),
    Acc1 = [Expr | Acc0],
    case End of
        End when End == ',' orelse End == comment -> exprs(Rest, Acc1, ForceBreak1);
        _ -> {End, ForceBreak1, lists:reverse(Acc1), Rest}
    end.

-spec expr(tokens(), force_break()) -> {dot | ';' | ',' | empty | comment, force_break(), doc(), tokens()}.
expr(Tokens, ForceBreak0) ->
    {ExprTokens, Rest} = get_end_of_expr(Tokens),
    {End, ForceBreak1, Expr} = expr(ExprTokens, empty(), ForceBreak0),
    {End, ForceBreak1, group(Expr), Rest}.

-spec expr(tokens(), doc(), force_break()) -> {dot | ';' | ',' | empty | comment, force_break(), doc()}.
expr([], Doc, ForceBreak) -> {empty, ForceBreak, Doc};
expr([{'?', _} | Rest0], Doc, ForceBreak0) ->
    % Handle macros
    {End, ForceBreak1, Expr, []} = expr(Rest0, ForceBreak0),
    {End, ForceBreak1, space(Doc, cons(text(<<"?">>), Expr))};
expr([{atom, LineNum, FunctionName}, {'(', LineNum} | _] = Tokens0, Doc, ForceBreak0) ->
    % Handle function calls
    Tokens1 = tl(Tokens0),
    {ListForceBreak, ListGroup, Rest} = list_group(Tokens1),
    ForceBreak1 = resolve_force_break([ForceBreak0, ListForceBreak]),
    Function =
        space(
          Doc,
          cons(
            text(a2b(FunctionName)),
            ListGroup
          )
        ),
    expr(Rest, Function, ForceBreak1);
expr([{C, _} | _] = Tokens, Doc, ForceBreak0) when ?IS_LIST_CHAR(C) ->
    {ListForceBreak, ListGroup, Rest} = list_group(Tokens),
    ForceBreak1 = resolve_force_break([ForceBreak0, ListForceBreak]),
    expr(Rest, space(Doc, ListGroup), ForceBreak1);
expr([{var, _, Var}, {'=', _} | Rest], Doc, ForceBreak0) ->
    % Handle equations
    % Arg3 =
    %     Arg1 + Arg2,
    Equals = group(space(text(a2b(Var)), text(<<"=">>))),
    {End, ForceBreak1, Expr} = expr(Rest, empty(), ForceBreak0),
    Equation = group(nest(?indent, space(Equals, group(Expr)))),
    {End, ForceBreak1, space(Doc, Equation)};
expr([{End, _}], Doc, ForceBreak) ->
    {End, ForceBreak, cons(Doc, text(a2b(End)))};
expr([{atom, _, Atom}, {'/', _}, {integer, _, Int} | Rest], Doc, ForceBreak) ->
    % Handle function arity expressions
    % some_fun/1
    FunctionDoc = cons(
                    [
                    text(a2b(Atom)),
                    text(<<"/">>),
                    text(i2b(Int))
                    ]
                   ),
    expr(Rest, space(Doc, FunctionDoc), ForceBreak);
expr([{var, _, Var}, {'/', _}, {atom, _, Atom} | Rest], Doc, ForceBreak) ->
    % Handle binary matching
    % <<Thing/binary>>
    TermDoc = cons([
                    text(a2b(Var)),
                    text(<<"/">>),
                    text(a2b(Atom))
                   ]),
    expr(Rest, space(Doc, TermDoc), ForceBreak);
expr([{var, _, Var}, {':', _}, {integer, _, Integer}, {'/', _}, {atom, _, Atom} | Rest], Doc, ForceBreak) ->
    % Handle more binary matching
    % <<Thing:1/binary, Rest/binary>>
    TermDoc =
        cons(
          [
           text(a2b(Var)),
           text(<<":">>),
           text(i2b(Integer)),
           text(<<"/">>),
           text(a2b(Atom))
          ]
        ),
    expr(Rest, space(Doc, TermDoc), ForceBreak);
expr([{var, _, Var}, {Op, _} | Rest], Doc0, ForceBreak) when ?IS_OPERATOR(Op) ->
    Doc1 = space(Doc0, space(text(a2b(Var)), text(a2b(Op)))),
    expr(Rest, Doc1, ForceBreak);
expr([{integer, _, Integer}, {Op, _} | Rest], Doc0, ForceBreak) when ?IS_OPERATOR(Op) ->
    Doc1 = space(Doc0, space(text(i2b(Integer)), text(a2b(Op)))),
    expr(Rest, Doc1, ForceBreak);
expr([{Token, _, Var} | Rest], Doc, ForceBreak) when Token == var orelse Token == atom ->
    expr(Rest, space(Doc, text(a2b(Var))), ForceBreak);
expr([{integer, _, Integer} | Rest], Doc, ForceBreak) ->
    expr(Rest, space(Doc, text(i2b(Integer))), ForceBreak);
expr([{string, _, Var} | Rest], Doc, ForceBreak) ->
    expr(Rest, space(Doc, text(s2b(Var))), ForceBreak);
expr([{comment, _, Comment}], Doc, _ForceBreak) ->
    {comment, force_break, space(Doc, comment(Comment))};
expr([{'|', _} | Rest0], Doc, ForceBreak0) ->
    {End, ForceBreak1, Expr} = expr(Rest0, empty(), ForceBreak0),
    Group = group(cons(text(<<"| ">>), group(Expr))),
    {End, ForceBreak1, space(Doc, Group)}.

-spec comment(string()) -> doc().
comment(Comment) -> text(list_to_binary(Comment)).

%% Internal

-spec format(integer(), integer(), list({integer(), mode(), doc()})) -> sdoc().
format(_, _, []) -> s_nil;
format(W, K, [{_, _, doc_nil} | Rest]) -> format(W, K, Rest);
format(W, K, [{I, M, {doc_cons, X, Y}} | Rest]) -> format(W, K, [{I, M, X}, {I, M, Y} | Rest]);
format(W, K, [{I, M, {doc_nest, J, X}} | Rest]) -> format(W, K, [{I + J, M, X} | Rest]);
format(W, K, [{_, _, {doc_text, S}} | Rest]) -> {s_text, S, format(W, K + byte_size(S), Rest)};
format(W, K, [{_, flat, {doc_break, S}} | Rest]) -> {s_text, S, format(W, K + byte_size(S), Rest)};
format(W, _, [{I, break, {doc_break, ?two_nl}} | Rest]) -> {s_line, 0, {s_line, I, format(W, I, Rest)}};
format(W, _, [{I, break, {doc_break, _}} | Rest]) -> {s_line, I, format(W, I, Rest)};
format(W, K, [{I, _, {doc_force_break, X}} | Rest]) -> format(W, K, [{I, break, X} | Rest]);
format(W, K, [{I, M, {doc_group, X, inherit}} | Rest]) -> format(W, K, [{I, M, X} | Rest]);
format(W, K, [{I, _, {doc_group, X, self}} | Rest]) ->
    case fits(W - K, [{I, flat, X}]) of
        true ->
            format(W, K, [{I, flat, X} | Rest]);
        false ->
            format(W, K, [{I, break, X} | Rest])
    end.

-spec fits(integer(), list({integer(), mode(), doc()})) -> boolean().
fits(W, _) when W < 0 -> false;
fits(_, []) -> true;
fits(W, [{_, _, doc_nil} | Rest]) -> fits(W, Rest);
fits(W, [{I, M, {doc_cons, X, Y}} | Rest]) -> fits(W, [{I, M, X}, {I, M, Y} | Rest]);
fits(W, [{I, M, {doc_nest, J, X}} | Rest]) -> fits(W, [{I + J, M, X} | Rest]);
fits(W, [{_, _, {doc_text, S}} | Rest]) -> fits(W - byte_size(S), Rest);
fits(W, [{_, flat, {doc_break, S}} | Rest]) -> fits(W - byte_size(S), Rest);
% This clause is impossible according to the research paper and dialyzer agrees.
%fits(_, [{_, break, {doc_break, _}} | _Rest]) -> throw(impossible);
fits(W, [{_, _, {doc_force_break, _}} | Rest]) -> fits(W, Rest);
fits(W, [{I, M, {doc_group, X, inherit}} | Rest]) -> fits(W, [{I, M, X} | Rest]);
fits(W, [{I, _, {doc_group, X, self}} | Rest]) -> fits(W, [{I, flat, X} | Rest]).

-spec sdoc_to_string(sdoc()) -> binary().
sdoc_to_string(s_nil) -> <<"">>;
sdoc_to_string({s_text, String, Doc}) ->
    DocString = sdoc_to_string(Doc),
    <<String/binary, DocString/binary>>;
sdoc_to_string({s_line, Indent, Doc}) ->
    Prefix = repeat(?sp, Indent),
    DocString = sdoc_to_string(Doc),
    <<"\n", Prefix/binary, DocString/binary>>.

%% Utils

-spec repeat(binary(), integer()) -> binary().
repeat(Bin, Times) when Times >= 0 -> repeat_(<<>>, Bin, Times).

-spec repeat_(binary(), binary(), integer()) -> binary().
repeat_(Acc, _, 0) -> Acc;
repeat_(Acc, Bin, Times) -> repeat_(<<Acc/binary, Bin/binary>>, Bin, Times - 1).

-spec a2b(atom()) -> binary().
a2b(dot) -> ?dot;
a2b(Atom) -> list_to_binary(atom_to_list(Atom)).

-spec i2b(integer()) -> binary().
i2b(Integer) -> integer_to_binary(Integer).

-spec s2b(string()) -> binary().
s2b(String) -> list_to_binary("\"" ++ String ++ "\"").

-spec get_until(atom(), atom(), tokens()) -> {tokens(), tokens(), token()}.
get_until(Start, End, Tokens) -> get_until(Start, End, Tokens, [], 0).

-spec get_until(atom(), atom(), tokens(), tokens(), integer()) -> {tokens(), tokens(), token()}.
get_until(Start, End, [{Start, _} = Token | Rest], Acc, Stack) ->
    get_until(Start, End, Rest, [Token | Acc], Stack + 1);
get_until(_Start, End, [{End, _} = Token | Rest], Acc, 0) ->
    {lists:reverse(Acc), Rest, Token};
get_until(Start, End, [{End, _} = Token | Rest], Acc, Stack) ->
    get_until(Start, End, Rest, [Token | Acc], Stack - 1);
get_until(Start, End, [Token | Rest], Acc, Stack) ->
    get_until(Start, End, Rest, [Token | Acc], Stack).

-spec remove_matching(atom(), atom(), tokens()) -> tokens().
remove_matching(Start, End, Tokens) -> remove_matching(Start, End, Tokens, [], 0).

-spec remove_matching(atom(), atom(), tokens(), tokens(), integer()) -> tokens().
remove_matching(Start, End, [{Start, _} = Token | Rest], Acc, Stack) ->
    remove_matching(Start, End, Rest, [Token | Acc], Stack + 1);
remove_matching(_Start, End, [{End, _} | Rest], Acc, 0) ->
    lists:reverse(Acc) ++ Rest;
remove_matching(Start, End, [{End, _} = Token | Rest], Acc, Stack) ->
    remove_matching(Start, End, Rest, [Token | Acc], Stack - 1);
remove_matching(Start, End, [Token | Rest], Acc, Stack) ->
    remove_matching(Start, End, Rest, [Token | Acc], Stack).

-spec get_end_of_expr(tokens()) -> {tokens(), tokens()}.
get_end_of_expr(Tokens) -> get_end_of_expr(Tokens, [], 0).

% Dialyzer gets upset if we use integer() for the third arg here but that's what it is.
-spec get_end_of_expr(tokens(), tokens(), any()) -> {tokens(), tokens()}.
get_end_of_expr([], Acc, _LineNum) ->
    {lists:reverse(Acc), []};
get_end_of_expr([{comment, _, _} = Comment | Rest], [], _LineNum) ->
    {[Comment], Rest};
get_end_of_expr([{comment, LineNum, _} = Comment | Rest], Acc, LineNum) ->
    % Inline comment - naughty naughty
    % Return the comment and put the acc back.
    {[Comment], lists:reverse(Acc) ++ Rest};
get_end_of_expr([{comment, _, _} | _] = Rest, Acc, _LineNum) ->
    {lists:reverse(Acc), Rest};
get_end_of_expr([{End, LineNum} = Token, {comment, LineNum, _} = Comment | Rest], Acc, _)
  when End == ',' orelse End == ';' orelse End == dot ->
    % Inline comment - naughty naughty
    % Return the comment and put the acc back.
    {[Comment], lists:reverse([Token | Acc]) ++ Rest};
get_end_of_expr([{End, _} = Token | Rest], Acc, _) when End == ',' orelse End == ';' orelse End == dot ->
    {lists:reverse([Token | Acc]), Rest};
get_end_of_expr([{'(', _} = Token | Rest0], Acc, _) ->
    {Tokens, Rest1, {')', LineNum} = EndToken} = get_until('(', ')', Rest0),
    get_end_of_expr(Rest1, [EndToken] ++ lists:reverse(Tokens) ++ [Token | Acc], LineNum);
get_end_of_expr([{'{', _} = Token | Rest0], Acc, _) ->
    {Tokens, Rest1, {'}', LineNum} = EndToken} = get_until('{', '}', Rest0),
    get_end_of_expr(Rest1, [EndToken] ++ lists:reverse(Tokens) ++ [Token | Acc], LineNum);
get_end_of_expr([{'[', _} = Token | Rest0], Acc, _) ->
    {Tokens, Rest1, {']', LineNum} = EndToken} = get_until('[', ']', Rest0),
    get_end_of_expr(Rest1, [EndToken] ++ lists:reverse(Tokens) ++ [Token | Acc], LineNum);
get_end_of_expr([{'<<', _} = Token | Rest0], Acc, _) ->
    {Tokens, Rest1, {'>>', LineNum} = EndToken} = get_until('<<', '>>', Rest0),
    get_end_of_expr(Rest1, [EndToken] ++ lists:reverse(Tokens) ++ [Token | Acc], LineNum);
get_end_of_expr([{_, LineNum} = Token | Rest], Acc, _) ->
    get_end_of_expr(Rest, [Token | Acc], LineNum);
get_end_of_expr([{_, LineNum, _} = Token | Rest], Acc, _) ->
    get_end_of_expr(Rest, [Token | Acc], LineNum).

-spec resolve_force_break(list(force_break())) -> force_break().
resolve_force_break(Args) ->
    case lists:any(fun(X) -> X == force_break end, Args) of
        true -> force_break;
        false -> no_force_break
    end.

%% Testing

test_binop(Left, Op, Right, Indent) ->
    group(
      nest(
        Indent,
        space(
          group(
            space(
              text(Left),
              text(Op)
            )
          ),
          text(Right)
        )
      )
    ).

test_ifthen(C, E1, E2, Indent) ->
    group(
      space(
        [
          group(nest(Indent, space(text(<<"if">>), C))),
          group(nest(Indent, space(text(<<"then">>), E1))),
          group(nest(Indent, space(text(<<"else">>), E2)))
        ]
      )
    ).

