FROM haproxy
MAINTAINER Volodymyr Kuznetsov <ks.vladimir@gmail.com>

ADD docker-entrypoint.sh /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
