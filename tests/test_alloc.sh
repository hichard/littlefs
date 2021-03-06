#!/bin/bash
set -euE
export TEST_FILE=$0
trap 'export TEST_LINE=$LINENO' DEBUG

echo "=== Allocator tests ==="
rm -rf blocks
scripts/test.py << TEST
    lfs_format(&lfs, &cfg) => 0;
TEST

SIZE=15000

lfs_mkdir() {
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;
    lfs_mkdir(&lfs, "$1") => 0;
    lfs_unmount(&lfs) => 0;
TEST
}

lfs_remove() {
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;
    lfs_remove(&lfs, "$1/eggs") => 0;
    lfs_remove(&lfs, "$1/bacon") => 0;
    lfs_remove(&lfs, "$1/pancakes") => 0;
    lfs_remove(&lfs, "$1") => 0;
    lfs_unmount(&lfs) => 0;
TEST
}

lfs_alloc_singleproc() {
scripts/test.py << TEST
    const char *names[] = {"bacon", "eggs", "pancakes"};
    lfs_file_t files[sizeof(names)/sizeof(names[0])];
    lfs_mount(&lfs, &cfg) => 0;
    for (unsigned n = 0; n < sizeof(names)/sizeof(names[0]); n++) {
        sprintf(path, "$1/%s", names[n]);
        lfs_file_open(&lfs, &files[n], path,
                LFS_O_WRONLY | LFS_O_CREAT | LFS_O_APPEND) => 0;
    }
    for (unsigned n = 0; n < sizeof(names)/sizeof(names[0]); n++) {
        lfs_size_t size = strlen(names[n]);
        for (int i = 0; i < $SIZE; i++) {
            lfs_file_write(&lfs, &files[n], names[n], size) => size;
        }
    }
    for (unsigned n = 0; n < sizeof(names)/sizeof(names[0]); n++) {
        lfs_file_close(&lfs, &files[n]) => 0;
    }
    lfs_unmount(&lfs) => 0;
TEST
}

lfs_alloc_multiproc() {
for name in bacon eggs pancakes
do
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;
    lfs_file_open(&lfs, &file, "$1/$name",
            LFS_O_WRONLY | LFS_O_CREAT | LFS_O_APPEND) => 0;
    lfs_size_t size = strlen("$name");
    memcpy(buffer, "$name", size);
    for (int i = 0; i < $SIZE; i++) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;
    lfs_unmount(&lfs) => 0;
TEST
done
}

lfs_verify() {
for name in bacon eggs pancakes
do
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;
    lfs_file_open(&lfs, &file, "$1/$name", LFS_O_RDONLY) => 0;
    lfs_size_t size = strlen("$name");
    for (int i = 0; i < $SIZE; i++) {
        lfs_file_read(&lfs, &file, buffer, size) => size;
        memcmp(buffer, "$name", size) => 0;
    }
    lfs_file_close(&lfs, &file) => 0;
    lfs_unmount(&lfs) => 0;
TEST
done
}

echo "--- Single-process allocation test ---"
lfs_mkdir singleproc
lfs_alloc_singleproc singleproc
lfs_verify singleproc

echo "--- Multi-process allocation test ---"
lfs_mkdir multiproc
lfs_alloc_multiproc multiproc
lfs_verify multiproc
lfs_verify singleproc

echo "--- Single-process reuse test ---"
lfs_remove singleproc
lfs_mkdir singleprocreuse
lfs_alloc_singleproc singleprocreuse
lfs_verify singleprocreuse
lfs_verify multiproc

echo "--- Multi-process reuse test ---"
lfs_remove multiproc
lfs_mkdir multiprocreuse
lfs_alloc_singleproc multiprocreuse
lfs_verify multiprocreuse
lfs_verify singleprocreuse

echo "--- Cleanup ---"
lfs_remove multiprocreuse
lfs_remove singleprocreuse

echo "--- Exhaustion test ---"
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;
    lfs_file_open(&lfs, &file, "exhaustion", LFS_O_WRONLY | LFS_O_CREAT);
    lfs_size_t size = strlen("exhaustion");
    memcpy(buffer, "exhaustion", size);
    lfs_file_write(&lfs, &file, buffer, size) => size;
    lfs_file_sync(&lfs, &file) => 0;

    size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    lfs_ssize_t res;
    while (true) {
        res = lfs_file_write(&lfs, &file, buffer, size);
        if (res < 0) {
            break;
        }

        res => size;
    }
    res => LFS_ERR_NOSPC;

    lfs_file_close(&lfs, &file) => 0;
    lfs_unmount(&lfs) => 0;
TEST
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;
    lfs_file_open(&lfs, &file, "exhaustion", LFS_O_RDONLY);
    lfs_size_t size = strlen("exhaustion");
    lfs_file_size(&lfs, &file) => size;
    lfs_file_read(&lfs, &file, buffer, size) => size;
    memcmp(buffer, "exhaustion", size) => 0;
    lfs_file_close(&lfs, &file) => 0;
    lfs_unmount(&lfs) => 0;
TEST

echo "--- Exhaustion wraparound test ---"
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;
    lfs_remove(&lfs, "exhaustion") => 0;

    lfs_file_open(&lfs, &file, "padding", LFS_O_WRONLY | LFS_O_CREAT);
    lfs_size_t size = strlen("buffering");
    memcpy(buffer, "buffering", size);
    for (int i = 0; i < $SIZE; i++) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;
    lfs_remove(&lfs, "padding") => 0;

    lfs_file_open(&lfs, &file, "exhaustion", LFS_O_WRONLY | LFS_O_CREAT);
    size = strlen("exhaustion");
    memcpy(buffer, "exhaustion", size);
    lfs_file_write(&lfs, &file, buffer, size) => size;
    lfs_file_sync(&lfs, &file) => 0;

    size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    lfs_ssize_t res;
    while (true) {
        res = lfs_file_write(&lfs, &file, buffer, size);
        if (res < 0) {
            break;
        }

        res => size;
    }
    res => LFS_ERR_NOSPC;

    lfs_file_close(&lfs, &file) => 0;
    lfs_unmount(&lfs) => 0;
TEST
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;
    lfs_file_open(&lfs, &file, "exhaustion", LFS_O_RDONLY);
    lfs_size_t size = strlen("exhaustion");
    lfs_file_size(&lfs, &file) => size;
    lfs_file_read(&lfs, &file, buffer, size) => size;
    memcmp(buffer, "exhaustion", size) => 0;
    lfs_file_close(&lfs, &file) => 0;
    lfs_remove(&lfs, "exhaustion") => 0;
    lfs_unmount(&lfs) => 0;
TEST

echo "--- Dir exhaustion test ---"
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;

    // find out max file size
    lfs_mkdir(&lfs, "exhaustiondir") => 0;
    lfs_size_t size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    lfs_file_open(&lfs, &file, "exhaustion", LFS_O_WRONLY | LFS_O_CREAT);
    int count = 0;
    int err;
    while (true) {
        err = lfs_file_write(&lfs, &file, buffer, size);
        if (err < 0) {
            break;
        }

        count += 1;
    }
    err => LFS_ERR_NOSPC;
    lfs_file_close(&lfs, &file) => 0;

    lfs_remove(&lfs, "exhaustion") => 0;
    lfs_remove(&lfs, "exhaustiondir") => 0;

    // see if dir fits with max file size
    lfs_file_open(&lfs, &file, "exhaustion", LFS_O_WRONLY | LFS_O_CREAT);
    for (int i = 0; i < count; i++) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;

    lfs_mkdir(&lfs, "exhaustiondir") => 0;
    lfs_remove(&lfs, "exhaustiondir") => 0;
    lfs_remove(&lfs, "exhaustion") => 0;

    // see if dir fits with > max file size
    lfs_file_open(&lfs, &file, "exhaustion", LFS_O_WRONLY | LFS_O_CREAT);
    for (int i = 0; i < count+1; i++) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;

    lfs_mkdir(&lfs, "exhaustiondir") => LFS_ERR_NOSPC;

    lfs_remove(&lfs, "exhaustion") => 0;
    lfs_unmount(&lfs) => 0;
TEST

echo "--- Chained dir exhaustion test ---"
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;

    // find out max file size
    lfs_mkdir(&lfs, "exhaustiondir") => 0;
    for (int i = 0; i < 10; i++) {
        sprintf(path, "dirwithanexhaustivelylongnameforpadding%d", i);
        lfs_mkdir(&lfs, path) => 0;
    }
    lfs_size_t size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    lfs_file_open(&lfs, &file, "exhaustion", LFS_O_WRONLY | LFS_O_CREAT);
    int count = 0;
    int err;
    while (true) {
        err = lfs_file_write(&lfs, &file, buffer, size);
        if (err < 0) {
            break;
        }

        count += 1;
    }
    err => LFS_ERR_NOSPC;
    lfs_file_close(&lfs, &file) => 0;

    lfs_remove(&lfs, "exhaustion") => 0;
    lfs_remove(&lfs, "exhaustiondir") => 0;
    for (int i = 0; i < 10; i++) {
        sprintf(path, "dirwithanexhaustivelylongnameforpadding%d", i);
        lfs_remove(&lfs, path) => 0;
    }

    // see that chained dir fails
    lfs_file_open(&lfs, &file, "exhaustion", LFS_O_WRONLY | LFS_O_CREAT);
    for (int i = 0; i < count+1; i++) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_sync(&lfs, &file) => 0;

    for (int i = 0; i < 10; i++) {
        sprintf(path, "dirwithanexhaustivelylongnameforpadding%d", i);
        lfs_mkdir(&lfs, path) => 0;
    }

    lfs_mkdir(&lfs, "exhaustiondir") => LFS_ERR_NOSPC;

    // shorten file to try a second chained dir
    while (true) {
        err = lfs_mkdir(&lfs, "exhaustiondir");
        if (err != LFS_ERR_NOSPC) {
            break;
        }

        lfs_ssize_t filesize = lfs_file_size(&lfs, &file);
        filesize > 0 => true;

        lfs_file_truncate(&lfs, &file, filesize - size) => 0;
        lfs_file_sync(&lfs, &file) => 0;
    }
    err => 0;

    lfs_mkdir(&lfs, "exhaustiondir2") => LFS_ERR_NOSPC;

    lfs_file_close(&lfs, &file) => 0;
    lfs_unmount(&lfs) => 0;
TEST

echo "--- Split dir test ---"
scripts/test.py << TEST
    lfs_format(&lfs, &cfg) => 0;
TEST
scripts/test.py << TEST
    lfs_mount(&lfs, &cfg) => 0;

    // create one block hole for half a directory
    lfs_file_open(&lfs, &file, "bump", LFS_O_WRONLY | LFS_O_CREAT) => 0;
    for (lfs_size_t i = 0; i < cfg.block_size; i += 2) {
        memcpy(&buffer[i], "hi", 2);
    }
    lfs_file_write(&lfs, &file, buffer, cfg.block_size) => cfg.block_size;
    lfs_file_close(&lfs, &file) => 0;

    lfs_file_open(&lfs, &file, "exhaustion", LFS_O_WRONLY | LFS_O_CREAT);
    lfs_size_t size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    for (lfs_size_t i = 0;
            i < (cfg.block_count-4)*(cfg.block_size-8);
            i += size) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;

    // remount to force reset of lookahead
    lfs_unmount(&lfs) => 0;
    lfs_mount(&lfs, &cfg) => 0;

    // open hole
    lfs_remove(&lfs, "bump") => 0;

    lfs_mkdir(&lfs, "splitdir") => 0;
    lfs_file_open(&lfs, &file, "splitdir/bump",
            LFS_O_WRONLY | LFS_O_CREAT) => 0;
    for (lfs_size_t i = 0; i < cfg.block_size; i += 2) {
        memcpy(&buffer[i], "hi", 2);
    }
    lfs_file_write(&lfs, &file, buffer, 2*cfg.block_size) => LFS_ERR_NOSPC;
    lfs_file_close(&lfs, &file) => 0;

    lfs_unmount(&lfs) => 0;
TEST

echo "--- Outdated lookahead test ---"
scripts/test.py << TEST
    lfs_format(&lfs, &cfg) => 0;

    lfs_mount(&lfs, &cfg) => 0;

    // fill completely with two files
    lfs_file_open(&lfs, &file, "exhaustion1",
            LFS_O_WRONLY | LFS_O_CREAT) => 0;
    lfs_size_t size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    for (lfs_size_t i = 0;
            i < ((cfg.block_count-2)/2)*(cfg.block_size-8);
            i += size) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;

    lfs_file_open(&lfs, &file, "exhaustion2",
            LFS_O_WRONLY | LFS_O_CREAT) => 0;
    size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    for (lfs_size_t i = 0;
            i < ((cfg.block_count-2+1)/2)*(cfg.block_size-8);
            i += size) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;

    // remount to force reset of lookahead
    lfs_unmount(&lfs) => 0;
    lfs_mount(&lfs, &cfg) => 0;

    // rewrite one file
    lfs_file_open(&lfs, &file, "exhaustion1",
            LFS_O_WRONLY | LFS_O_TRUNC) => 0;
    lfs_file_sync(&lfs, &file) => 0;
    size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    for (lfs_size_t i = 0;
            i < ((cfg.block_count-2)/2)*(cfg.block_size-8);
            i += size) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;

    // rewrite second file, this requires lookahead does not
    // use old population
    lfs_file_open(&lfs, &file, "exhaustion2",
            LFS_O_WRONLY | LFS_O_TRUNC) => 0;
    lfs_file_sync(&lfs, &file) => 0;
    size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    for (lfs_size_t i = 0;
            i < ((cfg.block_count-2+1)/2)*(cfg.block_size-8);
            i += size) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;
TEST

echo "--- Outdated lookahead and split dir test ---"
scripts/test.py << TEST
    lfs_format(&lfs, &cfg) => 0;

    lfs_mount(&lfs, &cfg) => 0;

    // fill completely with two files
    lfs_file_open(&lfs, &file, "exhaustion1",
            LFS_O_WRONLY | LFS_O_CREAT) => 0;
    lfs_size_t size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    for (lfs_size_t i = 0;
            i < ((cfg.block_count-2)/2)*(cfg.block_size-8);
            i += size) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;

    lfs_file_open(&lfs, &file, "exhaustion2",
            LFS_O_WRONLY | LFS_O_CREAT) => 0;
    size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    for (lfs_size_t i = 0;
            i < ((cfg.block_count-2+1)/2)*(cfg.block_size-8);
            i += size) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;

    // remount to force reset of lookahead
    lfs_unmount(&lfs) => 0;
    lfs_mount(&lfs, &cfg) => 0;

    // rewrite one file with a hole of one block
    lfs_file_open(&lfs, &file, "exhaustion1",
            LFS_O_WRONLY | LFS_O_TRUNC) => 0;
    lfs_file_sync(&lfs, &file) => 0;
    size = strlen("blahblahblahblah");
    memcpy(buffer, "blahblahblahblah", size);
    for (lfs_size_t i = 0;
            i < ((cfg.block_count-2)/2 - 1)*(cfg.block_size-8);
            i += size) {
        lfs_file_write(&lfs, &file, buffer, size) => size;
    }
    lfs_file_close(&lfs, &file) => 0;

    // try to allocate a directory, should fail!
    lfs_mkdir(&lfs, "split") => LFS_ERR_NOSPC;

    // file should not fail
    lfs_file_open(&lfs, &file, "notasplit",
            LFS_O_WRONLY | LFS_O_CREAT) => 0;
    lfs_file_write(&lfs, &file, "hi", 2) => 2;
    lfs_file_close(&lfs, &file) => 0;

    lfs_unmount(&lfs) => 0;
TEST

scripts/results.py
