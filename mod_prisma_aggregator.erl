-module(mod_prisma_aggregator).

-behavior(gen_mod).

-include("prisma_aggregator.hrl").
-include("jlib.hrl").

-define(CONNECTOR, aggregator_connector).
-define(SUP, prisma_aggregator_sup).

-compile(export_all).

-export([start/2, stop/1]).

%% gen_mod implementation
start(Host, Opts) ->
    inets:start(),
    Inets = inets:start(httpc, [{profile, ?INETS}]),
    ?INFO_MSG("inets started: ~p~n", [Inets]),
    setup_mnesia(),
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    ChildSpec = {?SUP,
                 {?SUP, start_link, [Host, Opts]},
                 permanent,
                 1000,
                 supervisor,
                 [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec),
    ?INFO_MSG("mod_prisma_aggregator starting!, module: ~p~n", [?MODULE]),

    % add a new virtual host / subdomain "echo".example.com
    MyHost = gen_mod:get_opt_host(Host, Opts, "aggregator.@HOST@"),
    ejabberd_router:register_route(MyHost, {apply, ?MODULE, route}),

   ok.

stop(Host) ->
    supervisor:terminate_child(ejabberd_sup, ?SUP),
    supervisor:delete_child(ejabberd_sup, ?SUP),
    mnesia:transaction(fun() -> mnesia:delete_table(?SPT) end),
    inets:stop(httpc, ?INETS),
    ?INFO_MSG("mod_prisma_aggregator stopping", []),
    ok.

%% interfacing fuctions


% Checks a presence /subscription/ is a part of this.
% we may want to impliment blacklisting / some kind of
% protection here to prevent malicious users
%route(From, #jid{luser = ?BOTNAME} = To, {xmlelement, "presence", _, _} = Packet) ->
route(From, To, {xmlelement, "presence", _, _} = Packet) ->
    case xml:get_tag_attr_s("type", Packet) of
        "subscribe" ->
            send_presence(To, From, "subscribe");
        "subscribed" ->
            send_presence(To, From, "subscribed"),
            send_presence(To, From, "");
        "unsubscribe" ->
            send_presence(To, From, "unsubscribed"),
            send_presence(To, From, "unsubscribe");
        "unsubscribed" ->
            send_presence(To, From, "unsubscribed");
        "" ->
            send_presence(To, From, "");
        "unavailable" ->
            ok;
        "probe" ->
            send_presence(To, From, "");
        _Other ->
            ?INFO_MSG("Other kind of presence~n~p", [Packet])
    end,
    ok;

route(From, To, {xmlelement, "message", _, _} = Packet) ->
    case xml:get_subtag_cdata(Packet, "body") of
	"" -> ok;
	"sag mal was anderes" -> echo(To, From, "was anderes");
	"spawn " ++ Id -> create_worker(Id),
			  ok;
	"stop " ++ Id -> ?CONNECTOR:stop(Id),
			  ok;
	"get_feed " ++ Params ->
	    {match, [Url, Id]} = re:run(Params, "(?<Id>.*) (?<Url>.*)", [{capture,['Url', 'Id'], list}]),
	    ?CONNECTOR:get_feed(From, To, Id, Url),
	    ok;
	Body ->
	    case xml:get_tag_attr_s("type", Packet) of
		
		"error" ->
		    ?ERROR_MSG("Received error message~n~p -> ~p~n~p", [From, To, Packet]);
		_ ->
		    echo(To, From, strip_bom(Body))
	    end
    end,
    ok;

route(_,_,Packet) -> 
    ?INFO_MSG("received unhandled packet:~n~p~n", [Packet]),
    ok.


%% HELPER FUNCTIONS

strip_bom([239,187,191|C]) -> C;
strip_bom(C) -> C.

send_presence(From, To, "") ->
    ejabberd_router:route(From, To, {xmlelement, "presence", [], []});

send_presence(From, To, TypeStr) ->
    ejabberd_router:route(From, To, {xmlelement, "presence", [{"type", TypeStr}], []}).

echo(From, To, Body) ->
    send_message(From, To, "chat", Body).

send_message(From, To, TypeStr, BodyStr) ->
    XmlBody = {xmlelement, "message",
           [{"type", TypeStr},
        {"from", jlib:jid_to_string(From)},
        {"to", jlib:jid_to_string(To)}],
           [{xmlelement, "body", [],
         [{xmlcdata, BodyStr}]}]},
    ejabberd_router:route(From, To, XmlBody).


%% internal functions

create_worker(Id) ->
    supervisor:start_child(?SUP, [Id]).

setup_mnesia() ->
    try 
	?INFO_MSG("In setup_mnesia, try", []),
	Info = mnesia:table_info(?SPT, all),
	?INFO_MSG("Table seems to exist:~n~p~n", [Info])
    catch _:{aborted, {no_exists, _, _}} -> 
	    ?INFO_MSG("In setup_mnesia, catch", []),
	    mnesia:create_table(?SPT,
			       [{attributes, record_info(fields, process_mapping)}]);
	  Type : Error -> ?INFO_MSG("In setup_mnesia, caught unknown msg:~n~p ->~n~p~n", [Type, Error])
    end.
