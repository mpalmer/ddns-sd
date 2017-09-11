FROM ruby:2.3-alpine

MAINTAINER Matt Palmer "matt.palmer@discourse.org"

COPY Gemfile Gemfile.lock /home/ddnssd/

RUN adduser -D ddnssd \
	&& docker_group="$(getent group 999 | cut -d : -f 1)" \
	&& if [ -z "$docker_group" ]; then addgroup -g 999 docker; docker_group=docker; fi \
	&& addgroup ddnssd "$docker_group" \
	&& apk update \
	&& apk add build-base \
	&& cd /home/ddnssd \
	&& su -pc 'bundle install --deployment --without development' ddnssd \
	&& apk del build-base \
	&& rm -rf /tmp/* /var/cache/apk/*

ARG GIT_REVISION=invalid-build
ENV DDNSSD_GIT_REVISION=$GIT_REVISION DDNSSD_DISABLE_LOG_TIMESTAMPS=yes

COPY bin/* /usr/local/bin/
COPY lib/ /usr/local/lib/ruby/2.3.0/

EXPOSE 9218
LABEL org.discourse.service._promex.port=9218 org.discourse.service._promex.instance=ddnssd

USER ddnssd
WORKDIR /home/ddnssd
ENTRYPOINT ["/usr/local/bin/bundle", "exec", "/usr/local/bin/ddns-sd"]
