%%% @author Sergey Prokhorov <me@seriyps.ru>
%%% @copyright (C) 2015, Sergey Prokhorov
%%% @doc
%%%
%%% @end
%%% Created : 20 Jan 2015 by Sergey Prokhorov <me@seriyps.ru>

-module(playpen_web_evaluate).

-export([init/3, handle/2, terminate/3]).

-export([from_urlencoded/2, from_json/2]).

-define(BODY_LIMIT, 102400).


-spec init({atom(), atom()}, cowboy_req:req(), [evaluate | compile]) ->
                  {ok, cowboy_req:req(), any()}.
init({tcp, http}, Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, State) ->
    lager:info("handle"),
    case cowboy_req:parse_header(<<"content-type">>, Req) of
        {ok, {<<"application">>, <<"x-www-form-urlencoded">>, _}, Req2} ->
            handle_body(Req2, State, from_urlencoded);
        {ok, {<<"application">>, <<"json">>, _}, Req2} ->
            handle_body(Req2, State, from_json);
        {error, badarg} ->
            {ok, Req2} = cowboy_req:reply(415, Req),
            {ok, Req2, State}
    end.

terminate(_, _Req, _State) ->
    ok.

handle_body(Req, State, ParserCallback) ->
    case cowboy_req:has_body(Req) of
        false ->
            {ok, Req2} = cowboy_req:reply(204, Req),
            {ok, Req2, State};
        true ->
            ?MODULE:ParserCallback(Req, State)
    end.


from_urlencoded(Req, State) ->
    lager:info("Urlencoded req"),
    case cowboy_req:body_qs(Req, [{length, ?BODY_LIMIT}, {read_length, ?BODY_LIMIT}]) of
        {ok, KV, Req2} ->
            handle_arguments(Req2, State, maps:from_list(KV));
        {badlength, Req2} ->
            %% Request body too long
            {ok, Req2} = cowboy_req:reply(400, Req),
            {ok, Req2, State};
        {error, _Reason} ->
            %% atom_to_list(Reason)
            {ok, Req2} = cowboy_req:reply(400, Req),
            {ok, Req2, State}
    end.

from_json(Req, State) ->
    lager:info("JSON req"),
    case cowboy_req:body(Req, [{length, ?BODY_LIMIT}, {read_length, ?BODY_LIMIT}]) of
        {ok, Data, Req1} ->
            try jiffy:decode(Data, [return_maps]) of
                KV when is_map(KV) ->
                    handle_arguments(Req1, State, KV)
            catch throw:_ ->
                    {ok, Req2} = cowboy_req:reply(400, [], "Invalid JSON", Req1),
                    {ok, Req2, State}
            end;
        {more, Req1} ->
            {ok, Req2} = cowboy_req:reply(400, [], "Request body too long", Req1),
            {ok, Req2, State};
        {error, Reason} ->
            {ok, Req2} = cowboy_req:reply(400, [], atom_to_list(Reason), Req),
            {ok, Req2, State}
    end.

handle_arguments(Req, [evaluate] = State, #{<<"code">> := SourceCode, <<"release">> := Release}) ->
    {ok, Releases} = application:get_env(eplaypen, releases),
    case lists:member(Release, Releases) of
        true ->
            Script = filename:join([code:priv_dir(eplaypen), "scripts", "evaluate.sh"]),
            run(Req, State, [Script, Release, integer_to_binary(iolist_size(SourceCode))], SourceCode);
        false ->
            {ok, Req2} = cowboy_req:reply(400, [], io_lib:format("Unknown release ~p", [Release]), Req),
            {ok, Req2, State}
    end;
handle_arguments(Req, [compile] = State, #{<<"code">> := SourceCode, <<"release">> := Release,
                                           <<"output_format">> := Output}) ->
    %% beam is erl_lint
    Formats = [<<"beam">>, % erl_lint                                 | erlc mod.erl
               <<"P">>,    % compile:forms(.., ['P'])                 | erlc -P mod.erl
               <<"E">>,    % compile:forms(.., ['E'])                 | erlc -E mod.erl
               <<"S">>,    % compile:forms(.., ['S'])                 | erlc -S mod.erl
               <<"dis">>,  % compile:forms(.., []), erts_debug:df(..) | erlc mod.erl && erl -eval 'erts_debug:df(mod).'
               <<"core">>],% compile:forms(.., [to_core])             | erlc +to_core mod.erl
    {ok, Releases} = application:get_env(eplaypen, releases),
    case {lists:member(Output, Formats), lists:member(Release, Releases)} of
        {true, true} ->
            Script = filename:join([code:priv_dir(eplaypen), "scripts", "compile.sh"]),
            run(Req, State, [Script, Release, integer_to_binary(iolist_size(SourceCode)), Output], SourceCode);
        {_, _} ->
            %% Invalid output format ~p or release ~p.
            {ok, Req2} = cowboy_req:reply(
                           400, [],
                           io_lib:format("Invalid output format ~p or release ~p",
                                         [Output, Release]), Req),
            {ok, Req2, State}
    end;
handle_arguments(Req, State, Payload) ->
    %% Invalid payload ~p.
    {ok, Req2} = cowboy_req:reply(400, [], io_lib:format("Invalid payload ~p", [Payload]), Req),
    {ok, Req2, State}.


-spec run(cowboy_req:req(), term(), list(), iodata()) -> {ok, cowboy_req:req(), term()}.
run(Req, State, Argv, SourceCode) ->
    {ok, Req1} = cowboy_req:chunked_reply(200, [{<<"content-type">>, <<"octet/stream">>}], Req),
    OutForm = text,
    Callback = fun(Chunk, Req2) ->
                       ok = cowboy_req:chunk(output_frame(Chunk, OutForm), Req2),
                       Req2
               end,
    PPOpts = #{},
    IOOpts = #{max_output_size => 512 * 1024,
               collect_output => false,
               timeout => 10000,
               output_callback => Callback,
               output_callback_state => Req1},
    case playpen_cmd:cmd(Argv, SourceCode, PPOpts, IOOpts) of
        {ok, {Code, _, Req3}} ->
            ok = cowboy_req:chunk(retcode_frame(Code, OutForm), Req3),
            {ok, Req3, State};
        {error, {output_too_large, _, Req3}} ->
            ok = cowboy_req:chunk(output_too_large_frame(OutForm), Req3),
            {ok, Req3, State};
        {error, {timeout, _, Req3}} ->
            ok = cowboy_req:chunk(timeout_frame(OutForm), Req3),
            {ok, Req3, State}
    end.

%% 1 - stdout/stderr     <<1, Size:24/little, Payload:Size/binary>>
%% 2 - return code       <<2, Code:8>>
%% 3 - output too large  <<3>>
%% 4 - timeout           <<4>>
output_frame(Chunk, binary) ->
    Size = <<1, (size(Chunk)):24/little>>,
    [Size, Chunk];
output_frame(Chunk, text) ->
    ["1|",
     integer_to_binary(size(Chunk)),
    "|", Chunk].

retcode_frame(Code, binary) ->
    <<2, Code>>;
retcode_frame(Code, text) ->
    ["2|", integer_to_binary(Code)].

output_too_large_frame(binary) ->
    <<3>>;
output_too_large_frame(text) ->
    <<"3">>.

timeout_frame(binary) ->
    <<4>>;
timeout_frame(text) ->
    <<"4">>.
