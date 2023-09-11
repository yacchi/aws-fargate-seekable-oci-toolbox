#!/bin/bash
set -eu

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 IMAGE_REF [--additional-tags]"
  echo "       $0 enter"
  exit 1
fi

# Start Containerd and wait a few seconds for it to stabilise
echo Starting Containerd
containerd >/dev/null 2>&1 &

if [[ $1 == "enter" ]]; then
  exec /bin/bash
fi

image_ref=$1
shift
additional_tags=

while (( $# > 0 )); do
  case "$1" in
  --additional-tags)
    additional_tags=1
    shift
    ;;
  *)
    echo "Unknown option: $1"
    exit 1
    ;;
  esac
done

sleep 3

# Test Containerd is working ok
ctr version >/dev/null

echo Pulling Container Image "$image_ref"
registry=
repository=
tag=

# Log into ECR
if [[ "$image_ref" == public* ]]; then
  if [[ "$image_ref" =~ ^public.ecr.aws/([^/]+)/([^:]+):([^:]+)$ ]]; then
    registry=${BASH_REMATCH[1]}
    repository=${BASH_REMATCH[2]}
    tag=${BASH_REMATCH[3]}
  else
    echo "Invalid image name: $image_ref"
    exit 1
  fi

  echo "Logging into ECR Public"
  # ECR Public only accepts the us-east-1 value for authentication
  PASSWORD=$(aws ecr-public get-login-password --region us-east-1)
  AWS_REGION=us-east-1
else
  if [[ "$image_ref" =~ ^([^/]+)/([^:]+):([^:]+)$ ]]; then
    registry=${BASH_REMATCH[1]}
    repository=${BASH_REMATCH[2]}
    tag=${BASH_REMATCH[3]}
  else
    echo "Invalid image name: $image_ref"
    exit 1
  fi

  if [[ "$registry" =~ ^([^\.]+)\.dkr\.ecr\.([^\.]+)\.amazonaws\.com$ ]]; then
    export AWS_REGION=${BASH_REMATCH[2]}
  else
    echo "Invalid registry name: $registry"
    exit 1
  fi

  echo "Logging into ECR"
  PASSWORD=$(aws ecr get-login-password)
fi

ARCH_VALUE=${IMAGE_ARCH:-"linux/amd64"}
ctr image pull \
  --platform="$ARCH_VALUE" \
  --user="AWS:${PASSWORD}" \
  "$image_ref" >/dev/null

# Create SOCI Index
echo Creating Soci Index
MIN_LAYER_SIZE_VALUE=${MIN_LAYER_SIZE:-10}
soci create --platform="$ARCH_VALUE" --min-layer-size "$MIN_LAYER_SIZE_VALUE" "$image_ref"

echo Pushing Soci Index
soci push --platform="$ARCH_VALUE" --user AWS:"$PASSWORD" "$image_ref"

ECR_PUBLIC_TOKEN=

get_manifest_from_public_ecr() {
  if [[ -z "$ECR_PUBLIC_TOKEN" ]]; then
    echo "ECR_PUBLIC_TOKEN is not set"
    exit 1
  fi
  local tag=$1
  curl -s -H "Authorization: Bearer ${ECR_PUBLIC_TOKEN}" "https://public.ecr.aws/v2/${registry}/${repository}/manifests/${tag}"
}

get_manifest_from_private_ecr() {
  aws ecr batch-get-image --repository-name "$repository" --image-ids "$1" --query images[0] --output json
}

if [[ -n "$additional_tags" ]]; then
  echo Attach additional tags to the image

  index_image_id=$(ctr image ls | grep "$image_ref" | awk '{print $3}' | sed 's/:/-/')

  if [[ "$image_ref" == public* ]]; then
    ECR_PUBLIC_TOKEN=$(curl -s https://public.ecr.aws/token/ | jq -r .token)
    index_manifest=$(get_manifest_from_public_ecr "${index_image_id}")
    soci_index_image_id=$(jq -r .manifests[0].digest <<<"$index_manifest")
    soci_index_manifest=$(get_manifest_from_public_ecr "${soci_index_image_id}")

    # delete the index image tag if it exists
    aws ecr-public batch-delete-image \
      --repository-name "$repository" \
      --image-ids imageTag="${tag}-index" --image-ids imageTag="${tag}-soci-index" || true

    # add '-index' suffix to the index image tag
    echo "Adding '${tag}-index' tag to the index image tag"
    aws ecr-public put-image \
      --repository-name "$repository" \
      --image-tag "${tag}-index" \
      --image-manifest "$index_manifest" \
      >/dev/null

    # add '-soci-index' suffix to the soci index image tag
    echo "Adding '${tag}-soci-index' tag to the soci index image tag"
    aws ecr-public put-image \
      --repository-name "$repository" \
      --image-tag "${tag}-soci-index" \
      --image-manifest "$soci_index_manifest" \
      >/dev/null

  else
    index_manifest=$(get_manifest_from_private_ecr imageTag="${index_image_id}")
    soci_index_image_id=$(jq -r .imageManifest <<<"$index_manifest" | jq -r '.manifests[0].digest')
    soci_index_manifest=$(get_manifest_from_private_ecr imageDigest="${soci_index_image_id}")

    # add '-index' suffix to the index image tag
    echo "Adding '${tag}-index' tag to the index image tag"
    aws ecr put-image \
      --repository-name "$repository" \
      --image-tag "${tag}-index" \
      --image-manifest "$(jq -r .imageManifest <<<"$index_manifest")" \
      >/dev/null || true

    # add '-soci-index' suffix to the soci index image tag
    echo "Adding '${tag}-soci-index' tag to the soci index image tag"
    aws ecr put-image \
      --repository-name "$repository" \
      --image-tag "${tag}-soci-index" \
      --image-manifest "$(jq -r .imageManifest <<<"$soci_index_manifest")" \
      >/dev/null || true
  fi
fi
