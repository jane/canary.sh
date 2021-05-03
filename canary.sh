#!/usr/bin/env bash
set -eo pipefail

canarysh_repo='https://github.com/jane/canary.sh'
canarysh=$(basename "$0")
canary_deployment=$DEPLOYMENT-$VERSION
working_dir=
# shellcheck disable=SC2153
if [ -n "$WORKING_DIR" ]; then
  working_dir=${WORKING_DIR%/}
else
  working_dir=$(mktemp -d)
fi

# GNU sed only. This is specified in the readme.
if hash gsed 2>/dev/null; then
  _sed=$(which gsed)
else
  _sed=$(which sed)
fi

usage() {
  cat <<EOF
$canarysh usage example:

NAMESPACE=books \\
  VERSION=v1.0.1 \\
  INTERVAL=30 \\
  TRAFFIC_INCREMENT=20 \\
  DEPLOYMENT=book-ratings \\
  SERVICE=book-ratings-loadbalancer \\
  $canarysh

These options would deploy version \`v1.0.1\` of \`book-ratings\` using the
image found in the previous version of the deployment with an updated
tag, in the \`books\` namespace, with traffic coming from the
\`book-ratings-loadbalancer\` service, migrating 20% of traffic at a time
to the new version at 30 second intervals.

Optional variables:
  KUBE_CONTEXT: defaults to currently selected context.
  HEALTHCHECK: path to executable to run instead of basing health
    on pod restarts. The command or script should return 0
    if healthy and anything else otherwise. If nothing is specified,
    pod restarts are used (see Kubernetes docs for probes).
  HPA: name of Horizontal Pod Autoscaler if there's one targeting
    this deployment.
  ON_FAILURE: path to executable to run if the canary healthcheck
    fails and rolls back.
  WORKING_DIR: defaults to \$(mktemp -d).

See $canarysh_repo for details.
EOF

  # Passed 0 or 1 from validate function
  exit "$1"
}

validate() {
  if ! hash kubectl 2>/dev/null; then
    echo "$canarysh: kubectl is required to use this program"
    exit 1
  fi

  # BSD sed doesn't have a --help flag
  $_sed --help >/dev/null 2>&1 || {
    echo "$canarysh: GNU sed is required"
    exit 1
  }

  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "$canarysh: Minimum supported Bash version is 4"
    exit 1
  fi

  # Match --help, -help, -h, help
  if [[ "$1" =~ "help" ]] || [[ "$1" =~ "-h" ]]; then
    usage 0
  fi

  if [ -z "$VERSION" ] || \
    [ -z "$SERVICE" ] || \
    [ -z "$DEPLOYMENT" ] || \
    [ -z "$TRAFFIC_INCREMENT" ] || \
    [ -z "$NAMESPACE" ] || \
    [ -z "$INTERVAL" ]; then
    usage 1
  fi
}

healthcheck() {
  log="[$canarysh ${FUNCNAME[0]}]"
  echo "$log Starting healthcheck"
  h=true

  if [ -n "$HEALTHCHECK" ]; then
    # Run whatever the user provided, check its exit code
    # Set +e so the parent (this script) doesn't exit
    set +e
    "$HEALTHCHECK"
    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
      h=false
    fi
    set -e
  else
    # K8s healthcheck
    output=$(kubectl get pods \
      -l app="$canary_deployment" \
      --no-headers)

    echo "$log $output"
    # shellcheck disable=SC2207
    s=($(echo "$output" | awk '{s+=$4}END{print s}'))
    # NAME READY STATUS RESTARTS AGE

    # Restart count. Restarts mean the probes are failing (or other issues,
    # unlhealthy either way).
    # shellcheck disable=SC2128
    if [ "$s" -gt "4" ]; then
      h=false
    fi
  fi

  if [ ! $h == true ]; then
    cancel "Healthcheck failed; canceling rollout"
    echo "$log Canary is unhealthy"
  else
    echo "$log Service healthy"
  fi
}

cancel() {
  log="[$canarysh ${FUNCNAME[0]}]"
  message=$1
  echo "$log $message"

  if [ -n "$ON_FAILURE" ]; then
    # We don't want to break our script if their thing fails
    set +e
    echo "$log Running \$ON_FAILURE"
    "$ON_FAILURE"
    set -e
  fi

  echo "$log $message"
  #TODO this is not the correct way to roll back a k8s deploy,
  #restore previous rs instead and stop changing the deploy name
  echo "$log Restoring original deployment to $prod_deployment"
  kubectl apply \
    --force \
    -f "$working_dir/original_deployment.yml"
  kubectl rollout status "deployment/$prod_deployment"

  echo "$log Removing canary deployment completely"
  kubectl delete deployment "$canary_deployment"

  echo "$log Restoring previous HPA"
  kubectl apply -f "$working_dir/original_hpa.yml"

  exit 1
}

cleanup() {
  log="[$canarysh ${FUNCNAME[0]}]"

  echo "$log Applying new HPA"
  kubectl apply -f "$working_dir/canary_hpa.yml"

  echo "$log Removing previous deployment $prod_deployment"
  kubectl delete deployment "$prod_deployment"

  echo "$log Marking canary as new production"
  kubectl get service "$SERVICE" -o=yaml | \
    $_sed -e "s/$current_version/$VERSION/g" | \
    kubectl apply -f -
}

increment_traffic() {
  log="[$canarysh ${FUNCNAME[0]}]"
  increment=$1
  max_replicas=$2


  prod_replicas=$(kubectl get deployment \
    "$prod_deployment" \
    -o=jsonpath='{.spec.replicas}')

  canary_replicas=$(kubectl get deployment \
    "$canary_deployment" \
     -o=jsonpath='{.spec.replicas}')

  new_prod_replicas=$((prod_replicas-increment))
  # Sanity check
  if [ "$new_prod_replicas" -lt "0" ]; then
    new_prod_replicas=0
  fi

  new_canary_replicas=$((canary_replicas+increment))
  # Sanity check
  if [ "$new_canary_replicas" -ge "$max_replicas" ]; then
    new_canary_replicas=$max_replicas
    new_prod_replicas=0
  fi

  echo "$log Setting canary replicas to $new_canary_replicas"
  kubectl scale --replicas="$new_canary_replicas" "deploy/$canary_deployment"

  echo "$log Setting production replicas to $new_prod_replicas"
  kubectl scale --replicas=$new_prod_replicas "deploy/$prod_deployment"

  # Verify scaling is where we expect
  time=0
  while [ "$(kubectl get deploy "$canary_deployment" -o=jsonpath='{.status.availableReplicas}')" -ne "$new_canary_replicas" ]; do
    sleep 2
    time=$((time+2))
    if [ "$time" -gt "300" ]; then
      cancel "timeout scaling up"
      exit 1
    fi
    echo -n "."
  done
  echo "$log Success:         canary replicas = $new_canary_replicas"
  time=0
  while [ "$(kubectl get deploy "$prod_deployment" -o=jsonpath='{.status.availableReplicas}')" -ne "$new_prod_replicas" ]; do
    sleep 2
    time=$((time+2))
    if [ "$time" -gt "60" ]; then
      cancel "timeout scaling down"
      exit 1
    fi
    echo -n "."
  done
  echo "$log Success: old production replicas = $new_prod_replicas"
}

copy_resources() {
#  # removed this step as the next one takes care of it, and using both creates
#  # a breaking edge case when current version is substr of version.
  log="[$canarysh ${FUNCNAME[0]}]"
#  # Replace old deployment name with new
#  $_sed -Ei -- "s/name\: $prod_deployment/name: $canary_deployment/g" "$working_dir/canary_deployment.yml"
#  echo "$log Replaced deployment name"

  # Replace docker image
  $_sed -Ei -- "s/$current_version/$VERSION/g" "$working_dir/canary_deployment.yml"
  echo "$log Replaced image in deployment"
  echo "$log Production deployment is $prod_deployment, canary is $canary_deployment"

  # $_sed -Ei -- "s/$current_version/$VERSION/g" "$working_dir/canary_hpa.yml"
  $_sed -Ei -- "s/name\: $prod_deployment/name: $canary_deployment/g" "$working_dir/canary_hpa.yml"
  echo "$log Replaced target in HPA"
}

main() {
  log="[$canarysh ${FUNCNAME[0]}]"
  if [ -n "$KUBE_CONTEXT" ]; then
    echo "$log Setting Kubernetes context"
    kubectl config use-context "${KUBE_CONTEXT}"
  else
    echo "$log ---WARNING: running canaries without passing kube_context is dangerous and support for that pattern will soon end---"
  fi
  echo "$log Setting Kubernetes namespace to ${NAMESPACE}"
  { #try
    kubectl get namespace "${NAMESPACE}"
  } || { #catch
    echo "$log namespace not found.  You may need to set your KUBE_CONTEXT"
    echo "$log KUBE_CONTEXT was set to ${KUBE_CONTEXT} for this build"
    echo "$log Aborting"
    exit 1
  }
  kubectl config set-context --current --namespace="${NAMESPACE}"

  echo "$log Getting current version"
  current_version=$(kubectl get service "$SERVICE" -o=jsonpath='{.metadata.labels.version}')

  if [ -z "$current_version" ]; then
    echo "$log No current version found"
    echo "$log Do you have metadata.labels.version set?"
    echo "$log Aborting"
    exit 1
  fi

  if [ "$current_version" == "$VERSION" ]; then
   echo "$log VERSION matches current_version: $current_version"
   exit 0
  fi

  echo "$log Current version is $current_version"
  prod_deployment=$DEPLOYMENT-$current_version

  echo "$log Getting current deployment"
  kubectl get deployment "$prod_deployment" -o=yaml > "$working_dir/canary_deployment.yml"

  echo "$log Backing up original deployment"
  cp "$working_dir/canary_deployment.yml" "$working_dir/original_deployment.yml"

  if [ -n "$HPA" ]; then
    echo "$log Getting current HPA"
    kubectl get hpa "$HPA" -o=yaml > "$working_dir/canary_hpa.yml"
    cp "$working_dir/canary_hpa.yml" "$working_dir/original_hpa.yml"
  fi

  echo "$log Finding current replicas"

  # Copy existing resources and update
  copy_resources
  log="[$canarysh ${FUNCNAME[0]}]"
  starting_replicas=$(kubectl get deployment "$prod_deployment" -o=jsonpath='{.spec.replicas}')
  echo "$log Found replicas $starting_replicas"

  echo "$log Removing previous HPA"
  kubectl delete -f "$working_dir/canary_hpa.yml"

  echo "$log calculating increment..."

  # find increment float, convert to int(floor), and round up to 1 if needed
  pod_increment=$((TRAFFIC_INCREMENT*starting_replicas/100))
  pod_increment=${pod_increment%.*}
  if [ "$pod_increment" -lt "1" ]; then
    pod_increment=1
  fi
  echo "$log pods will be incremented by $pod_increment"
  # Launch one replica first
  $_sed -Ei -- "s#replicas: $starting_replicas#replicas: 1#g" "$working_dir/canary_deployment.yml"
  echo "$log Launching 1 pod with canary"
  kubectl apply -f "$working_dir/canary_deployment.yml"

  echo -n "$log Waiting for canary pod"
  time=0
  #check to make sure everything is set up correctly for our query to return a number
  isNumber='^[0-9]+$'

  while [ -z "$(kubectl get deploy "$canary_deployment" -o=jsonpath='{.status.availableReplicas}')" ]; do
    sleep 2
    time=$((time+2))
    if [ "$time" -gt "600" ]; then
      cancel "timeout waiting for k8s deploy to build"
      exit 1
    fi
    echo -n "."
  done
  kubectlResult="$(kubectl get deploy "$canary_deployment" -o=jsonpath='{.status.availableReplicas}')"
  if ! [[ $kubectlResult =~ $isNumber ]]; then
    echo "$log kubectl expected a numbered response, instead got:"
    echo "$log $kubectlResult"
    echo "$log Aborting"
    cancel "non-numbered kubectl response"
    exit 1
  fi
  time=0
  while [ "$(kubectl get deploy "$canary_deployment" -o=jsonpath='{.status.availableReplicas}')" -eq 0 ]; do
    sleep 2
    time=$((time+2))
    if [ "$time" -gt "600" ]; then
      cancel "timeout deploying first replica"
      exit 1
    fi
    echo -n "."
  done
  echo ''
  echo "$log Canary target replicas: $starting_replicas"

  healthcheck
  log="[$canarysh ${FUNCNAME[0]}]"

  echo "$log scaling canaries to $starting_replicas by increments of $pod_increment"
  while true; do
    if [ "$(kubectl get deploy "$canary_deployment" -o=jsonpath='{.status.availableReplicas}')" -ge "$starting_replicas" ]; then
      cleanup
      echo "$log Done"
      exit 0
    fi
    increment_traffic "$pod_increment" "$starting_replicas"
    log="[$canarysh ${FUNCNAME[0]}]"
    echo "$log Sleeping for $INTERVAL seconds"
    sleep "$INTERVAL"
    healthcheck
    log="[$canarysh ${FUNCNAME[0]}]"
  done

}

validate "$@"
main
