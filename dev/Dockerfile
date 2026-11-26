# rpmdev: Windows(Docker Desktop)에서 build-rpm.sh / test-rpm.sh 를 서버와 같은 조건으로 실행하기 위한 개발 환경
#   - 테스트 서버와 같은 Rocky Linux 9
#   - docker CLI 포함 (호스트의 Docker Desktop 엔진을 /var/run/docker.sock 으로 사용)
#   - rpm, createrepo_c, python3-rpm: build-rpm.sh 의 결과 검사·저장소 갱신용
# 이미지는 dev.ps1 이 자동으로 만든다.
FROM docker:20.10-cli AS dockercli

FROM rockylinux/rockylinux:9
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
RUN set -eux; \
    dnf -y install rpm-build rpmdevtools createrepo_c python3-rpm systemd-rpm-macros \
                   xz tar gzip bzip2 findutils procps-ng which less vim-minimal; \
    command -v curl >/dev/null || dnf -y install curl-minimal; \
    dnf clean all
ENV BUILD_MODE=container
CMD ["bash"]
