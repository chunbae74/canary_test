#!/bin/bash
function update_nginx_weight() {
    # 입력값: $1 = blue 트래픽 비율, $2 = green 트래픽 비율 (예: update_nginx_weight 90 10)
    local BLUE=$1; local GREEN=$2

    # 비율이 0보다 큰 서버만 명단에 이어붙입니다(+=). weight=0은 문법 오류라 아예 제외!
    CONF="upstream backend {"
    [ "$BLUE" -gt 0 ] && CONF+=" server app-blue:8080 weight=$BLUE;"
    [ "$GREEN" -gt 0 ] && CONF+=" server app-green:8081 weight=$GREEN;"
    CONF+=" }"

    # 완성된 설정을 Nginx 컨테이너 안에 덮어쓰고 프록시를 리로드 처리합니다.
    docker exec nginx-proxy sh -c "echo '$CONF' > /etc/nginx/conf.d/upstream.inc"
    docker exec nginx-proxy nginx -s reload
}

# 1. 호스트 내 app-blue 명칭 컨테이너의 가동 생존 여부 검색
IS_BLUE=$(docker ps -q -f name="^app-blue$")

# 검색 결과 존재(Blue 가동 중) 시, 신규 배포를 수행할 타겟 서버는 Green으로 교차 스위칭
if [ -n "$IS_BLUE" ]; then
    CURRENT="blue"; TARGET="green"; TARGET_PORT=8081; TARGET_COLOR="🟢 GREEN"
else
    CURRENT="green"; TARGET="blue"; TARGET_PORT=8080; TARGET_COLOR="🔵 BLUE"
fi

# 2. 최신 릴리즈 소스코드를 기반으로 신규 도커 이미지를 구워냅니다.
docker build -t my-canary-app .

# 3. 이전 배포 실패 등 잔재로 남아있는 타겟 컨테이너 찌꺼기 존재 시 사전 강제 파기
docker rm -f app-$TARGET 2>/dev/null

# 4. 신규 컨테이너를 가상 네트워크망(canary-net)에 결속시켜 환경 변수 기반 구동 실행
docker run -d --name app-$TARGET --network canary-net \
    -e PORT=$TARGET_PORT -e COLOR="$TARGET_COLOR" \
    my-canary-app

# 5. 서버 내부 런타임 부팅을 위한 최소 대기 시간 부여 후, 프록시망 내부 접근 시도
sleep 5
RESPONSE=$(docker exec nginx-proxy sh -c "wget -qO- http://app-$TARGET:${TARGET_PORT}")

# 수신된 응답 문자열 패킷 미존재 시 서비스 불가로 판단, 즉각 컨테이너 파기(Rollback)
if [ -z "$RESPONSE" ]; then
    echo "❌ 헬스체크 실패! 신규 서버 통신 접근 불가. 즉시 롤백 처리합니다."
    docker rm -f app-$TARGET
    exit 1
fi


i# 1단계: 신규 버전에 카나리 10% 트래픽 최초 할당 후 시스템 지표 15초 관측 대기
if [ "$TARGET" == "green" ]; then update_nginx_weight 90 10; else update_nginx_weight 10 90; fi
sleep 15

# 2단계: 구/신 서버 50:50 균등 분할로 트래픽 상향 전환 인가 후 15초 추가 모니터링
update_nginx_weight 50 50
sleep 15

# 3단계: 신규 릴리즈 버전 100% 완전 라우팅 전환 확정 달성
if [ "$TARGET" == "green" ]; then update_nginx_weight 0 100; else update_nginx_weight 100 0; fi

# 라우팅 트래픽 배분 목적이 완전 종료된 이전 버전(Legacy) 컨테이너 인스턴스 파기
docker rm -f app-$CURRENT
