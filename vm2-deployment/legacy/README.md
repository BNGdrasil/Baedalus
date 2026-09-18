# vm2-deployment/legacy

이 디렉터리에 있는 파일은 더 이상 배포 경로에서 사용하지 않는다. 지우지 않고 남겨 둔 이유는
과거 배포본을 해석할 때 참고 자료가 필요하기 때문이다. 새 작업에서는 사용하지 않는다.

| 파일 | 대체된 이유 |
|---|---|
| `config/services.json` | Bifrost 서비스 등록부가 PostgreSQL의 `services` 테이블로 옮겨졌다. 운영 VM2의 `/opt/bnbong/bifrost/config/services.json`은 아직 mount되어 있으나 등록 항목이 하나뿐이며, DB 등록부만으로 기동하는 것을 확인한 뒤에 mount와 함께 제거한다. |
| `create-service.sh` | 새 서비스를 `docker-compose.<name>.yml`과 JSON 등록부로 추가하던 스크립트다. 존재하지 않는 `msa-network`를 전제하고 있었고, 서비스 등록 역시 DB 등록부와 Bifrost 관리 API가 담당한다. |

두 파일이 참조하던 JSON 등록부를 실제로 없애려면 Bifrost가 DB 등록부만으로 기동하는지를
먼저 확인해야 한다. 그 확인이 끝나기 전까지는 운영 compose의 `./bifrost/config` mount를
그대로 둔다.
