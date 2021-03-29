FROM python:3.7.9

RUN apt-get update && apt-get install -y \
    # Install packages required for debugging via gdb + debugpy.
    libc6-dbg \
    valgrind \
    texinfo \
    inotify-tools && \
    rm -rf /var/lib/apt/lists/*

# Fetch and build gdb from source.
# Save installation for the destination Dockerfile.
RUN wget "http://ftp.gnu.org/gnu/gdb/gdb-10.1.tar.xz" && tar -xf \
    "gdb-10.1.tar.xz" && \
    cd gdb-10.1 && \
    ./configure && \
    # These two steps take an inordinate amount of time.
    # In real usage it is probably best to move `make` to a shared
    # Dockerfile and leave the installation to dev only containers.
    make && \
    make install

RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app
COPY ./ ./

RUN pip install pip==20.2.2

RUN pip install -r requirements.txt
