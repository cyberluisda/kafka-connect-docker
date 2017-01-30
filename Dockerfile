FROM ches/kafka:0.10.1.0

MAINTAINER Luis David Barrios Alfonso (luisdavid.barrios@agsnasoft.com / cyberluisda@gmail.com)

USER root

ADD files/kafka-connect.sh /bin/
RUN chmod a+x /bin/kafka-connect.sh

USER kafka

VOLUME /usr/lib/kafka/connect-extra /etc/kafka-connect

ENV CLASSPATH /usr/lib/kafka/connect-extra/*

EXPOSE 8083

ENTRYPOINT ["/bin/kafka-connect.sh"]
CMD ["--help"]
