%%--------------------------------------------------------------------
%% Copyright (c) 2013-2017 EMQ Enterprise, Inc. (http://emqtt.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emq_auth_redis_SUITE).

-compile(export_all).

-include_lib("emqttd/include/emqttd.hrl").

-include_lib("common_test/include/ct.hrl").

-include_lib("eunit/include/eunit.hrl").

-include("emq_auth_redis.hrl").

-define(POOL(App),  ecpool_worker:client(gproc_pool:pick_worker({ecpool, App}))).

-define(INIT_ACL, [{"mqtt_acl:test1", "topic1", "2"},
                   {"mqtt_acl:test2", "topic2", "1"},
                   {"mqtt_acl:test3", "topic3", "3"}]).

-define(INIT_AUTH, [{"mqtt_user:plain", ["password", "plain", "salt", "salt", "is_superuser", "1"]},
                    {"mqtt_user:md5", ["password", "1bc29b36f623ba82aaf6724fd3b16718", "salt", "salt", "is_superuser", "0"]},
                    {"mqtt_user:sha", ["password", "d8f4590320e1343a915b6394170650a8f35d6926", "salt", "salt", "is_superuser", "0"]},
                    {"mqtt_user:sha256", ["password", "5d5b09f6dcb2d53a5fffc60c4ac0d55fabdf556069d6631545f42aa6e3500f2e", "salt", "salt", "is_superuser", "0"]},
                    {"mqtt_user:pbkdf2_password", ["password", "cdedb5281bb2f801565a1122b2563515", "salt", "ATHENA.MIT.EDUraeburn", "is_superuser", "0"]},
                    {"mqtt_user:bcrypt_foo", ["password", "$2a$12$sSS8Eg.ovVzaHzi1nUHYK.HbUIOdlQI0iS22Q5rd5z.JVVYH6sfm6", "salt", "$2a$12$sSS8Eg.ovVzaHzi1nUHYK.", "is_superuser", "0"]}]).

all() -> 
    [{group, emq_auth_redis_auth},
     {group, emq_auth_redis_acl},
     {group, emq_auth_redis},
     {group, auth_redis_config}
    ].

groups() -> 
    [{emq_auth_redis_auth, [sequence],
     [check_auth, list_auth, check_auth_hget]},
    {emq_auth_redis_acl, [sequence],
     [check_acl, acl_super]},
    {emq_auth_redis, [sequence],
     [comment_config]},
     {auth_redis_config, [sequence], [server_config]}
].

init_per_suite(Config) ->
    DataDir = proplists:get_value(data_dir, Config),
    Apps = [start_apps(App, DataDir) || App <- [emqttd, emq_auth_redis]],
    ct:log("Apps:~p", [Apps]),
    Config.

end_per_suite(Config) ->
    {ok, Connection} = ?POOL(?APP), 
    AuthKeys = [Key || {Key, _Filed, _Value} <- ?INIT_AUTH],
    AclKeys = [Key || {Key, _Value} <- ?INIT_ACL],
    eredis:q(Connection, ["DEL" | AuthKeys]),
    eredis:q(Connection, ["DEL" | AclKeys]),
    application:stop(emq_auth_redis),
    application:stop(ecpool).

check_auth(Config) ->
    {ok, Connection} = ?POOL(?APP), 
    [eredis:q(Connection, ["HMSET", Key|FiledValue]) || {Key, FiledValue} <- ?INIT_AUTH],
    Plain = #mqtt_client{client_id = <<"client1">>, username = <<"plain">>},
    Md5 = #mqtt_client{client_id = <<"md5">>, username = <<"md5">>},
    Sha = #mqtt_client{client_id = <<"sha">>, username = <<"sha">>},
    Sha256 = #mqtt_client{client_id = <<"sha256">>, username = <<"sha256">>},
    Pbkdf2 = #mqtt_client{client_id = <<"pbkdf2_password">>, username = <<"pbkdf2_password">>},
    Bcrypt = #mqtt_client{client_id = <<"bcrypt_foo">>, username = <<"bcrypt_foo">>},
    User1 = #mqtt_client{client_id = <<"bcrypt_foo">>, username = <<"user">>},
    User3 = #mqtt_client{client_id = <<"client3">>},
    {error, username_or_password_undefined} = emqttd_access_control:auth(User3, <<>>),
    reload([{password_hash, plain}]),
    {ok, true} = emqttd_access_control:auth(Plain, <<"plain">>),
    reload([{password_hash, md5}]),
    {ok, false} = emqttd_access_control:auth(Md5, <<"md5">>),
    reload([{password_hash, sha}]),
    {ok, false} = emqttd_access_control:auth(Sha, <<"sha">>),
    reload([{password_hash, sha256}]),
    {ok, false} = emqttd_access_control:auth(Sha256, <<"sha256">>),
    %%pbkdf2 sha
    reload([{password_hash, {pbkdf2, sha, 1, 16}}, {auth_cmd, "HMGET mqtt_user:%u password salt"}]),
    {ok, false} = emqttd_access_control:auth(Pbkdf2, <<"password">>),
    reload([{password_hash, {salt, bcrypt}}]),
    {ok, false} = emqttd_access_control:auth(Bcrypt, <<"foo">>),
    ok = emqttd_access_control:auth(User1, <<"foo">>).

list_auth(_Config) ->
    application:start(emq_auth_username),
    emq_auth_username:add_user(<<"user1">>, <<"password1">>),
    User1 = #mqtt_client{client_id = <<"client1">>, username = <<"user1">>},
    ok = emqttd_access_control:auth(User1, <<"password1">>),
    reload([{password_hash, plain}, {auth_cmd, "HMGET mqtt_user:%u password"}]),
    Plain = #mqtt_client{client_id = <<"client1">>, username = <<"plain">>},
    {ok, true} = emqttd_access_control:auth(Plain, <<"plain">>),
    Stop = application:stop(emq_auth_username),
    ct:log("Stop:~p~n", [Stop]).

check_auth_hget(Config) ->
    {ok, Connection} = ?POOL(?APP), 
    eredis:q(Connection, ["HSET", "mqtt_user:hset", "password", "hset"]),
    eredis:q(Connection, ["HSET", "mqtt_user:hset", "is_superuser", "1"]),
    reload([{password_hash, plain}, {auth_cmd, "HGET mqtt_user:%u password"}]),
    Hset = #mqtt_client{client_id = <<"hset">>, username = <<"hset">>},
    {ok, true} = emqttd_access_control:auth(Hset, <<"hset">>).

check_acl(Config) ->
    {ok, Connection} = ?POOL(?APP), 
    Result = [eredis:q(Connection, ["HSET", Key, Filed, Value]) || {Key, Filed, Value} <- ?INIT_ACL],
    User1 = #mqtt_client{client_id = <<"client1">>, username = <<"test1">>},
    User2 = #mqtt_client{client_id = <<"client2">>, username = <<"test2">>},
    User3 = #mqtt_client{client_id = <<"client3">>, username = <<"test3">>},
    User4 = #mqtt_client{client_id = <<"client4">>, username = <<"$$user4">>},
    deny = emqttd_access_control:check_acl(User1, subscribe, <<"topic1">>),
    allow = emqttd_access_control:check_acl(User1, publish, <<"topic1">>),

    deny = emqttd_access_control:check_acl(User2, publish, <<"topic2">>),
    allow = emqttd_access_control:check_acl(User2, subscribe, <<"topic2">>),
    allow = emqttd_access_control:check_acl(User3, publish, <<"topic3">>),
    allow = emqttd_access_control:check_acl(User3, subscribe, <<"topic3">>),
    allow = emqttd_access_control:check_acl(User4, publish, <<"a/b/c">>).

acl_super(_Config) ->
    reload([{password_hash, plain}]),
    {ok, C} = emqttc:start_link([{host, "localhost"}, {client_id, <<"simpleClient">>}, {username, <<"plain">>}, {password, <<"plain">>}]),
    timer:sleep(10),
    emqttc:subscribe(C, <<"TopicA">>, qos2),
    timer:sleep(1000),
    emqttc:publish(C, <<"TopicA">>, <<"Payload">>, qos2),
    timer:sleep(1000),
    receive
        {publish, Topic, Payload} ->
        ?assertEqual(<<"Payload">>, Payload)
    after
        1000 ->
        io:format("Error: receive timeout!~n"),
        ok
    end,
    emqttc:disconnect(C).

comment_config(_) ->
    application:stop(?APP),
    [application:unset_env(?APP, Par) || Par <- [acl_cmd, auth_cmd]],
    application:start(?APP),
    ?assertEqual([], emqttd_access_control:lookup_mods(auth)),
    ?assertEqual([], emqttd_access_control:lookup_mods(acl)).

server_config(_) ->
    I = [{host, "localhost"},
         {pool_size, 1},
         {port, 6377},
         {auto_reconnect, 1},
         {password, "public"},
         {database, 1}
       ],
    SetConfigKeys = ["server=localhost:6377",
                     "pool=1",
                     "password=public",
                     "database=1",
                     "password_hash=salt,sha256"],
    lists:foreach(fun set_cmd/1, SetConfigKeys),
    {ok, E} =  application:get_env(emq_auth_redis, server),
    {ok, Hash} =  application:get_env(emq_auth_redis, password_hash),
    ?assertEqual(lists:sort(I), lists:sort(E)),
    ?assertEqual({salt,sha256}, Hash).

set_cmd(Key) ->
    emqttd_cli_config:run(["config", "set", string:join(["auth.redis", Key], "."), "--app=emq_auth_redis"]).

start_apps(App, DataDir) ->
    Schema = cuttlefish_schema:files([filename:join([DataDir, atom_to_list(App) ++ ".schema"])]),
    Conf = conf_parse:file(filename:join([DataDir, atom_to_list(App) ++ ".conf"])),
    NewConfig = cuttlefish_generator:map(Schema, Conf),
    Vals = proplists:get_value(App, NewConfig),
    [application:set_env(App, Par, Value) || {Par, Value} <- Vals],
    application:ensure_all_started(App).

reload(Config) when is_list(Config) ->
    application:stop(?APP),
    [application:set_env(?APP, K, V) || {K, V} <- Config],
    application:start(?APP).


