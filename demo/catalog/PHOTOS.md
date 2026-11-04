# Фото демо-каталога по макету

Тестовые данные демо «Оптомстрой POS»: веб-демо (ADR-113) и демо Windows. Каталог —
`design-catalog.json` (WP-DATA-WEB, 2026-10-31; 15 ADR-114). Здесь — откуда взяты картинки и на каких условиях
они публикуются.

## Права

Решение владельца от 2026-10-31 (ответ на Q-338, вопрос 2): фото из макета использовать **как демо-данные**. Сервер
отдаёт их так же, как фото из 1С: картинки категорий — через `categories.image_id`, фото товаров — обычными фото
товара. В сборку приложения они **не встраиваются**: в настоящем магазине картинки групп придут из 1С, а пока их
нет — иконки. Названия и марки товаров (Sanita, Kirovit, AquaLine, River, Geberit) приведены как в макете, «как
есть» (Q-336).

Изображения товаров и категорий — материалы заказчика из макета, только для демонстрации; права — у
правообладателей. Та же строка есть в `THIRD_PARTY_NOTICES.txt` сайта (`demo/web/backend/notices/build-notices.mjs`).
Сайт веб-демо публичный (noindex, WEB-KI-19), поэтому картинки можно скачать по прямой ссылке.

## Происхождение

Файлы скопированы побайтно из отслеживаемой копии макета `docs/specification/visual/prototype/assets/`, а не из
`NEW DESIGN/`. Это файлы, загруженные в инструмент дизайна. Копии совпадают с `NEW DESIGN/assets/` байт в байт.

- Картинки не перекодированы и не увеличены. WebP-размеры thumb 160, card 400 и full 1200 делает `processImage`
  pos-api без увеличения, поэтому card и full равны исходному размеру — как в самом макете.
- Сборка снимка веб-демо проверяет sha256 каждого файла по `design-catalog.json` → `photos[]`. Тест
  `demo/web/backend/test/design-catalog.test.mjs` дополнительно сверяет файлы с ассетами макета.
- Недостатки исходников оставлены как в макете: персиковый фон у значка «Сантехника», розовый у «Унитазов»,
  обрывок текста «Крепеж и» на значке «Крепеж и фурнитура». Картинки маленькие и размываются при масштабе
  Windows 125–150 % и на экранах 2× (PRT-KI-12).
- Логотип макета (`25202bdd….png`, 38×38) сюда не входит: это не данные каталога, в шапке — официальный
  оранжевый логотип (Q-006).

29 файлов, 259 158 байт (PNG RGB, без альфа-канала):

| Файл | Ассет макета (`docs/specification/visual/prototype/`) | Чей | Пиксели | Байт | sha256 |
|---|---|---|---|---|---|
| photos/cat-heating.png | assets/546298e04342487169e63bf370870029.png | корень «Отопление» | 65×48 | 3943 | `ee8d4f7b95065628b4fd9a42ba3c8706fb86c9d1246afd18597bb97097ba022f` |
| photos/cat-plumbing.png | assets/6c7b2573872e04181eedbabcf138e0dd.png | корень «Сантехника» | 45×41 | 3437 | `de2798558b549c5615f0baca89a2f44205f4e31b25f5288bdb085c058399b560` |
| photos/cat-water.png | assets/18871ec73e897ad0554a169f16aeda41.png | корень «Водоснабжение» | 65×45 | 4760 | `e0749aa1e8fa39cb605d147410684df9d38b3a8fe20f1aa8e0cf0c64cc0a2a4d` |
| photos/cat-electric.png | assets/d4a861c04df4812da554030fc9e4ffc7.png | корень «Электрика» | 65×47 | 3457 | `4a7bfede26ef017ef744d326eda1eab12eb48a4a2fe462fbfc1f1b60fb058211` |
| photos/cat-vent.png | assets/468d4c01b2c789f1e21efcbc907b1597.png | корень «Вентиляция» | 65×47 | 5675 | `c5903f1d282c7c5629ceebc2ed36d3f68828ff83b688c15575cbdace0628d2b1` |
| photos/cat-build.png | assets/2671204efe725bfe9d3d5db9158c1fa6.png | корень «Строительные материалы» | 65×42 | 5171 | `a3696964ebbcf855f970be9684f5061258e261dd890a00e586703980c818023c` |
| photos/cat-tools.png | assets/4377c3605c298c5e3a224c6f3355b991.png | корень «Инструменты» | 65×48 | 5010 | `b5dc4faa4966188c46aade549787e99ef87e1750baf25b2597e92b3bd7760242` |
| photos/cat-fasteners.png | assets/876d016d574cb37baebadcb499ec0a69.png | корень «Крепеж и фурнитура» | 65×42 | 3854 | `f37e6a755db01bc595010918a5e3520c7a63e9823887cf02ce7eb0e8ac5443f5` |
| photos/sub-toilets.png | assets/d11b39a04f20cb98c11d14a0cdf8dd43.png | подкатегория «Унитазы» | 86×94 | 6667 | `d17e72b1b84aa467f0c274f8cabe81176f8ff7f0e4e8846a8090653bf4828bd0` |
| photos/sub-sinks.png | assets/14b1f345d22161b24c14878b919417a9.png | подкатегория «Раковины» | 110×100 | 7326 | `5afcf167e904127ec723a785f040c3c7b6d3c25aa09c13c914695499aa05ddb5` |
| photos/sub-baths.png | assets/d2d53b6a0f3611a133465e3a67c327c3.png | подкатегория «Ванны» | 112×100 | 6216 | `5b887a1f2a1d381ca838b2cb7c8edcb2c4125edc562ba8828867b11698f64cf0` |
| photos/sub-showers.png | assets/358ea61c9831eaaafde6a5186cc60f53.png | подкатегория «Душевые кабины» | 114×106 | 10193 | `e238a2ee832b4184d3fdb7542d9d1bcd7a1d4670c1feb6c23939139aa19beaba` |
| photos/sub-install.png | assets/95723393aba8a436eee4d53e6ee59e4f.png | подкатегория «Инсталляции» | 113×106 | 10715 | `83b7bc111e0af1121bb034cc633f0d114fcd0857c92c99828addf96736a05faa` |
| photos/sub-bidet.png | assets/703a0345cb913baad2a1341ed2fde391.png | подкатегория «Биде» | 113×100 | 6848 | `169cfebf528bfb31c35012f9ef911eb5f570ac9775dddb7d69c76c9f55ab4fbc` |
| photos/sub-urinals.png | assets/9dd040f9ed38deb930020675eee7fdcf.png | подкатегория «Писсуары» | 110×106 | 5756 | `0a713df35f60948f7f8bca291ea773e3c6eb705d7d0c115bb39a3b45177537a3` |
| photos/sub-siphons.png | assets/62448b65c9a018b29e46c5d645646680.png | подкатегория «Сифоны» | 108×100 | 9509 | `b198ea93bd988dcd5df7148509965c14c0be3946ab92b9b2785fd1d8696308b7` |
| photos/sub-pipes.png | assets/3882010e534dcc3989297708b0ada6a6.png | подкатегория «Канализационные трубы и фитинги» | 68×97 | 9280 | `f0e1683e843e2ee1de9e62c820e9b2912f64f0e48d2d10e811d99e807f248ac8` |
| photos/p-toilet.png | assets/7ce996d8b6cf797732db4f25e31fd393.png | товар SL1001 «Унитаз-компакт Sanita Luxe Classic» | 158×125 | 9779 | `6150ad4b26afbbc7d09290d2412734b8227afdc39978a088e299716a0c0508d4` |
| photos/p-sink.png | assets/3d2267029dd6016c1ea180c0bf46fa87.png | товар KVM021 «Раковина накладная Kirovit KVM-021» | 164×125 | 9927 | `3258d4dc65825b498315bb7b6e6cc24dd22dc107a18210d3d71f91a9346779dd` |
| photos/p-bath.png | assets/2def3ed384b10a363787ae6626a485d9.png | товар AL17070 «Ванна акриловая AquaLine 170x70» | 172×125 | 11673 | `c16eaeeca1dd9914e0d6788acf9d5bf032712cbfb9033118e70402a2bf628e29` |
| photos/p-shower.png | assets/86a927d35176488b6306ee75e3e4593e.png | товар RV9090 «Душевая кабина River 90x90» | 168×125 | 15092 | `cee569de34ae1c0705dccbc5fe746d04d60ef9ad3e540cccfeefc4d0cf92b0e2` |
| photos/p-install.png | assets/0cc91975cf5245eee7c104eb65149fb1.png | товар GD112 «Инсталляция для унитаза Geberit Duofix» | 174×125 | 16743 | `bca75606a932817d32dc66c3395fab212c4c077206902f467a7a0a115318fa4d` |
| photos/p-bidet.png | assets/17b994f133d85e576cec062b50821123.png | товар SB200 «Биде напольное Sanita» | 174×125 | 12269 | `079020ad84d6ba5890defa03b416f66fa73acf74d17759f1af99d80c07443548` |
| photos/p-urinal.png | assets/91ee2af9e3dd8f7805571fb3df0b9681.png | товар SP300 «Писсуар подвесной Sanita Pro» | 158×109 | 7215 | `d5b2497ab1a170402055975383b893063fa5ea42737e0440182a3455fa1a2459` |
| photos/p-siphon.png | assets/8950e785262161a94a5b3331000fedd0.png | товар SF450 «Сифон для раковины бутылочный хром» | 164×109 | 11806 | `283505ac295a65431542aa27682f9a62875b3a2eecccf54fecdba05a7cbe3e7a` |
| photos/p-pipes.png | assets/46a28a8290f4315e59c7fd6778ba1df6.png | товар KT110 «Тройник канализационный 110 мм» | 172×109 | 19498 | `7f4d21b75c904c88bee7c4a26463c87a2c865c867e698ec3616489814608c626` |
| photos/p-vanity.png | assets/b57b3de12c3290cbdbef0f9d94d63ea0.png | товар TR600 «Тумба с раковиной 60 см белая» | 168×109 | 10251 | `6ce90a34b437601d009d7c301d9c9a045849e4b62f6db8b729e35bc0bfe13ca7` |
| photos/p-tray.png | assets/7c85a959f72311e8b8fd561ffea070cb.png | товар PD9090 «Поддон акриловый 90x90» | 174×109 | 12788 | `f7668c425585c6c4b2b3cd42d1732d86b58caaa58725a641efd4bb7641f5e6aa` |
| photos/p-towel.png | assets/35c646961926ffd91dc458dd2870a56c.png | товар PS5080 «Полотенцесушитель водяной 50x80» | 174×109 | 14300 | `8773a3f640b2a9a3be7949917843244a741ac3a2b3a1f7bd42904d429fab4eae` |

У товаров вне «Сантехники» (26 товаров макета без фото и все наполнители) фото нет: приложение показывает заглушку
«Фото появится из 1С», как макет. У подкатегорий вне «Сантехники» картинок тоже нет: в ленте — значок из
четырёх квадратов.

## Как заменить или добавить фото

1. Положите PNG в `photos/` под именем `<имя>.png`.
2. Добавьте запись в `photos[]` в `design-catalog.json`: имя, файл, источник (путь к исходнику в репозитории;
   тест сверяет с ним байты), sha256 и роль `product:<артикул>` или `category:<id>[/<id>]`.
3. Укажите имя фото в поле `photo` товара или `image` категории.
4. Проверьте: `node --test demo/web/backend/test/design-catalog.test.mjs`.
5. Пересоберите: `node demo/web/backend/build-backend.mjs`. Ключ эпохи изменится, и браузеры начнут демо заново
   (WEB-KI-06).
