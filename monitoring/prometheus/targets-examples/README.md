# 원격 exporter target 예시

`prometheus.yml`의 `vm1-nginx` job과 `vm3-postgres` job은 file_sd로 동작하며, 아래 두 경로를
대상 파일로 지정하고 있습니다.

```
/etc/prometheus/targets/remote/vm1-nginx.json
/etc/prometheus/targets/remote/vm3-postgres.json
```

이 디렉터리의 `*.json.example`은 그 파일에 넣을 내용입니다. 파일이 없으면 Prometheus는 해당
job의 target을 만들지 않으므로, exporter를 설치하기 전까지는 `TargetDown` 경보가 울리지
않습니다.

두 디렉터리를 나눈 이유는 배포 방식이 서로 다르기 때문입니다. 이 `targets-examples/`
디렉터리는 배포 워크플로의 rsync가 그대로 전송하므로 저장소의 내용이 VM2에 반영됩니다.
반면 `targets/`는 rsync의 제외 대상이어서, 그 아래에 만든 파일은 배포를 반복해도 지워지지
않습니다. 즉 정의는 저장소가 관리하고, 활성화 여부는 운영 서버가 유지합니다.

활성화 절차와 확인 방법은 [../../README.md](../../README.md)의 "원격 exporter 수집 활성화"
항목에 적어 두었습니다.
