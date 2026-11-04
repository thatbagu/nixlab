# Container images for the VM tests (they have no internet), pinned by digest
# and hash. Update with:
#   nix run nixpkgs#nix-prefetch-docker -- --image-name <name> --image-tag <tag> --quiet
# and keep them in sync with the images the render uses.
{ pkgs }:

{
  argocd = pkgs.dockerTools.pullImage {
    imageName = "quay.io/argoproj/argocd";
    imageDigest = "sha256:097c922fb910e6bb0278b0e26382f88de4fa5c966564111bddd334051b0e63d7";
    hash = "sha256-/NDpUXALQw6UMHLEzAEZAQIVW2l85HT+KpYsbwh3MCA=";
    finalImageTag = "v3.4.1";
  };
  redis = pkgs.dockerTools.pullImage {
    imageName = "ecr-public.aws.com/docker/library/redis";
    imageDigest = "sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba";
    hash = "sha256-uao+VHcBa3kuM46wLFHUbP71iAAEl/sg79xicQx3zp0=";
    finalImageTag = "8.2.3-alpine";
  };
  whoami = pkgs.dockerTools.pullImage {
    imageName = "docker.io/traefik/whoami";
    imageDigest = "sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab";
    hash = "sha256-qBTCdI2Hf7Rd8SCWOge0ZtJ+gK5C1Ztq/XfeU5clMew=";
    finalImageTag = "v1.11.0";
  };
}
