FROM 394389787758.dkr.ecr.us-east-1.amazonaws.com/ruby:2.3.0

RUN apt-get update &&\
    apt-get install -y -q sqlite3 libsqlite3-dev libpq-dev &&\
    rm -rf /var/lib/apt/lists/*

ENV USE_ENV true
ENV WORKDIR /opt/services/hello-world-ruby
ENV BUNDLE_PATH /var/bundle
ENV GEM_HOME $BUNDLE_PATH
ENV HOME $WORKDIR
ENV BUNDLE_APP_CONFIG $GEM_HOME
ENV CUSTOM_RUBY_VERSION 2.3.0

RUN groupadd app &&\
    useradd -g app -d $WORKDIR -s /sbin/nologin -c 'Docker image user for the app' app &&\
    mkdir -p $WORKDIR $BUNDLE_PATH

WORKDIR /opt/services/hello-world-ruby

ADD Gemfile /opt/services/hello-world-ruby/
ADD Gemfile.lock /opt/services/hello-world-ruby/

RUN bundle install --without debug --path $BUNDLE_PATH

ADD . /opt/services/hello-world-ruby

RUN chown -R app:app $WORKDIR $BUNDLE_PATH

USER app

CMD foreman start

