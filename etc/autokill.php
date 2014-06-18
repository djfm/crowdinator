<?php

$dir = dirname(__FILE__);

foreach(new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST) as $path) {
    $path->isDir() ? rmdir($path->getPathname()) : unlink($path->getPathname());
}
rmdir($dir);
