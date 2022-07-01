FROM alpine:edge

RUN apk add git neovim python3 --update && \
  # create symlink for python, because lua only calls python not python3
  ln -s $(which python3) /usr/bin/python 

RUN git clone --depth 1 https://github.com/nvim-lua/plenary.nvim /root/.local/share/nvim/site/pack/vendor/start/plenary.nvim
COPY lua/ /root/.local/share/nvim/site/pack/vendor/start/lua
COPY tests/ /root/.local/share/nvim/site/pack/vendor/start/tests
WORKDIR /root/.local/share/nvim/site/pack/vendor/start/
ENTRYPOINT [ "nvim" ]

