PROJECT = emq_auth_redis
PROJECT_DESCRIPTION = Authentication/ACL with Redis
PROJECT_VERSION = 2.3

COVER = true

ERLC_OPTS += +debug_info
ERLC_OPTS += +'{parse_transform, lager_transform}'

include erlang.mk

app:: rebar.config

app.config::
	deps/cuttlefish/cuttlefish -l info -e etc/ -c etc/emq_set_redis.conf -i priv/emq_set_redis.schema -d data
