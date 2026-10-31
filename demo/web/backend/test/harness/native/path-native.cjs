'use strict';
// Эталон WP-T1: настоящий node:path в варианте POSIX — как у сервера pos-api (Linux) и как у шима бандла.
// На Windows `path` Node — win32 (C:\…), и пути виртуальной раскладки /vfs/… получили бы букву диска.
const path = require('node:path');
module.exports = path.posix;
