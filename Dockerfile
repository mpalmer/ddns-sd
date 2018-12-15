FROM ruby:2.6

COPY Gemfile Gemfile.lock /home/ddnssd/

RUN useradd -M -N -r -s /bin/bash -u 1000 -o ddnssd \
	&& docker_group="$(getent group 999 | cut -d : -f 1)" \
	&& if [ -z "$docker_group" ]; then groupadd -g 999 docker; docker_group=docker; fi \
	&& usermod -a -G "$docker_group" ddnssd \
	&& apt-get update \
	&& apt-get install -y libpq-dev libpq5 libsqlite3-0 libsqlite3-dev \
	&& cd /home/ddnssd \
	&& chown -R ddnssd . \
	&& su -pc 'bundle install --deployment --without "development route53_backend azure_backend"' ddnssd \
	&& apt-get purge -y libpq-dev libsqlite3-dev \
	&& apt-get autoremove -y --purge \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

ARG GIT_REVISION=invalid-build
ENV DDNSSD_GIT_REVISION=$GIT_REVISION DDNSSD_DISABLE_LOG_TIMESTAMPS=yes

COPY bin/* /usr/local/bin/
COPY lib/ /usr/local/lib/ruby/2.6.0/

EXPOSE 9218
LABEL org.discourse.service._prom-exp.port=9218 org.discourse.service._prom-exp.instance=ddns-sd

USER ddnssd
WORKDIR /home/ddnssd
ENTRYPOINT ["/usr/local/bin/bundle", "exec", "/usr/local/bin/ddns-sd"]
