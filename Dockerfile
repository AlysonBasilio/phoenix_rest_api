FROM elixir:1.10.1-alpine

ARG USER_ID
ARG GROUP_ID

RUN addgroup -g $GROUP_ID user_group
RUN adduser -D -g '' -u $USER_ID -G user_group user
USER user

RUN mix local.hex --force && mix archive.install hex phx_new 1.4.13 --force
