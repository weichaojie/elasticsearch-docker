#!/bin/bash
set -e

# Create random user entry, if different from uid 1000, to support Openshift
# https://docs.openshift.org/latest/creating_images/guidelines.html
if ! whoami &> /dev/null; then
    if [ -w /etc/passwd ]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:/usr/share/elasticsearch:/sbin/nologin" >> /etc/passwd
    fi
fi

run_as_other_user_if_needed() {
    if [[ "$(id -u)" == "0" ]]; then
        # If running as root, drop to specified UID and run command
        exec chroot --userspec=1000 / "${@}"
    else
        # Either we are running in Openshift with random uid and are a member of the root group
        # or with a custom --user
        exec "${@}"
    fi
}

# Allow user specify custom CMD, maybe bin/elasticsearch itself
# for example to directly specify `-E` style parameters for elasticsearch on k8s
# or simply to run /bin/bash to check the image
if [[ "$1" != "eswrapper" ]]; then
    if [[ "$(id -u)" == "0" ]] && [[ "$1" == *elasticsearch* ]]; then
        exec chroot --userspec=1000 / "$@"
    else
        exec "$@"
    fi
fi

# Parse Docker env vars to customize Elasticsearch
#
# e.g. Setting the env var cluster.name=testcluster
#
# will cause Elasticsearch to be invoked with -Ecluster.name=testcluster
#
# see https://www.elastic.co/guide/en/elasticsearch/reference/current/settings.html#_setting_default_settings

declare -a es_opts

while IFS='=' read -r envvar_key envvar_value
do
    # Elasticsearch env vars need to have at least two dot separated lowercase words, e.g. `cluster.name`
    if [[ "$envvar_key" =~ ^[a-z_]+\.[a-z_]+ ]]; then
        if [[ ! -z $envvar_value ]]; then
          es_opt="-E${envvar_key}=${envvar_value}"
          es_opts+=("${es_opt}")
        fi
    fi
done < <(env)

# The virtual file /proc/self/cgroup should list the current cgroup
# membership. For each hierarchy, you can follow the cgroup path from
# this file to the cgroup filesystem (usually /sys/fs/cgroup/) and
# introspect the statistics for the cgroup for the given
# hierarchy. Alas, Docker breaks this by mounting the container
# statistics at the root while leaving the cgroup paths as the actual
# paths. Therefore, Elasticsearch provides a mechanism to override
# reading the cgroup path from /proc/self/cgroup and instead uses the
# cgroup path defined the JVM system property
# es.cgroups.hierarchy.override. Therefore, we set this value here so
# that cgroup statistics are available for the container this process
# will run in.
export ES_JAVA_OPTS="-Des.cgroups.hierarchy.override=/ $ES_JAVA_OPTS"

# Determine if x-pack is enabled
if bin/elasticsearch-plugin list -s | grep -q x-pack; then
    # Setting ELASTIC_PASSWORD is mandatory on the *first* node (unless
    # LDAP is used). As we have no way of knowing if this is the first
    # node at this step, we can't enforce the presence of this env
    # var.
    if [[ -n "$ELASTIC_PASSWORD" ]]; then
        [[ -f config/elasticsearch.keystore ]] || run_as_other_user_if_needed "bin/elasticsearch-keystore" "create"
        run_as_other_user_if_needed echo "$ELASTIC_PASSWORD" | bin/elasticsearch-keystore add -x 'bootstrap.password'
    fi

    # ALLOW_INSECURE_DEFAULT_TLS_CERT=true permits the use of a
    # pre-bundled self signed cert for transport TLS.
    # This should be used strictly on non-production environments.
    if [[ "$ALLOW_INSECURE_DEFAULT_TLS_CERT" == "true" ]]; then
        es_opts+=( '-Expack.security.authc.token.enabled=false'
                   '-Expack.ssl.verification_mode=certificate'
                   '-Expack.ssl.key=x-pack/node01/node01.key'
                   '-Expack.ssl.certificate=x-pack/node01/node01.crt'
                   '-Expack.ssl.certificate_authorities=x-pack/ca/ca.crt'
                 )
    fi
fi

if [[ "$(id -u)" == "0" ]]; then
    # If requested and running as root, mutate the ownership of bind-mounts
    if [[ -n "$MUTATE_MOUNTS" ]]; then
        chown -R 1000:0 /usr/share/elasticsearch/{data,logs}
    fi
fi

run_as_other_user_if_needed /usr/share/elasticsearch/bin/elasticsearch "${es_opts[@]}"
