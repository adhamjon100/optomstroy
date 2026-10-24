/**
 * Allow-list стандартного OData 1С для пользователя `pos_integration` (ONEC-083, RM-B-004) — проекция
 * `contracts/onec/odata-allowlist.yaml` (коллекции, допустимые операции и поля). Совпадение с YAML проверяет
 * `test/onec/odata-allowlist.spec.ts`; правка контракта = правка этого файла (13 §2 «риски»: имя объекта 1С —
 * конфигурация, а не код маппинга). Рантайм не читает YAML: пакет `yaml` — только devDependency.
 */
export type ODataCollectionKind =
  | 'catalog'
  | 'tabularSection'
  | 'chartOfCharacteristicTypes'
  | 'informationRegister'
  | 'accumulationRegister'
  | 'document';

export type ODataOperation = 'list' | 'balance' | 'sliceLast';

export interface ODataAllowedCollection {
  readonly name: string;
  readonly kind: ODataCollectionKind;
  readonly operations: readonly ODataOperation[];
  readonly fields: readonly string[];
  /** ONEC-106: объект может отсутствовать — шаг пропускается без ошибки. */
  readonly conditional: boolean;
}

/** `odata.maxTop` (ONEC-085: `$top` ≤ 2000). */
export const ODATA_MAX_TOP = 2000;
/** `odata.pageSize` — `ONEC_SYNC_PAGE_SIZE` по умолчанию. */
export const ODATA_DEFAULT_PAGE_SIZE = 1000;
/** `deniedExamples` (AC-ONEC-083) и `excluded` — заведомо запрещены. */
export const ODATA_DENIED: readonly string[] = ['Catalog_Пользователи', 'AccountingRegister_Хозрасчетный'];

export const ODATA_ALLOWLIST: readonly ODataAllowedCollection[] = [
  {
    name: 'Catalog_Номенклатура',
    kind: 'catalog',
    operations: ['list'],
    fields: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'IsFolder',
      'Code',
      'Description',
      'НаименованиеПолное',
      'Артикул',
      'Parent_Key',
      'ЕдиницаИзмерения_Key',
      'ВидНоменклатуры_Key',
      'ТипНоменклатуры',
      'Описание',
      'ФайлКартинки_Key',
      'Весовой',
    ],
    conditional: false,
  },
  {
    name: 'Catalog_Номенклатура_ДополнительныеРеквизиты',
    kind: 'tabularSection',
    operations: ['list'],
    fields: ['Ref_Key', 'Свойство_Key', 'Значение', 'Значение_Type'],
    conditional: false,
  },
  {
    name: 'ChartOfCharacteristicTypes_ДополнительныеРеквизитыИСведения',
    kind: 'chartOfCharacteristicTypes',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Description'],
    conditional: false,
  },
  {
    name: 'Catalog_ЗначенияСвойствОбъектов',
    kind: 'catalog',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Description', 'Owner_Key'],
    conditional: false,
  },
  {
    name: 'Catalog_ХарактеристикиНоменклатуры',
    kind: 'catalog',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Code', 'Description', 'Owner_Key', 'Owner_Type'],
    conditional: true,
  },
  {
    name: 'Catalog_КлассификаторЕдиницИзмерения',
    kind: 'catalog',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Code', 'Description'],
    conditional: false,
  },
  {
    name: 'Catalog_УпаковкиЕдиницыИзмерения',
    kind: 'catalog',
    operations: ['list'],
    fields: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'Description',
      'Owner_Key',
      'Owner_Type',
      'Коэффициент',
      'ЕдиницаИзмерения_Key',
    ],
    conditional: true,
  },
  {
    name: 'InformationRegister_ШтрихкодыНоменклатуры',
    kind: 'informationRegister',
    operations: ['list'],
    fields: ['Штрихкод', 'Номенклатура_Key', 'Характеристика_Key', 'Упаковка_Key', 'ТипШтрихкода'],
    conditional: false,
  },
  {
    name: 'Catalog_НоменклатураПрисоединенныеФайлы',
    kind: 'catalog',
    operations: ['list'],
    fields: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'ВладелецФайла_Key',
      'Размер',
      'Расширение',
      'ДатаМодификацииУниверсальная',
    ],
    conditional: false,
  },
  {
    name: 'Catalog_Склады',
    kind: 'catalog',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'IsFolder', 'Code', 'Description'],
    conditional: false,
  },
  {
    name: 'AccumulationRegister_ТоварыНаСкладах',
    kind: 'accumulationRegister',
    operations: ['balance'],
    fields: ['Номенклатура_Key', 'Характеристика_Key', 'Склад_Key', 'ВНаличииBalance'],
    conditional: false,
  },
  {
    name: 'AccumulationRegister_СвободныеОстатки',
    kind: 'accumulationRegister',
    operations: ['balance'],
    fields: [
      'Номенклатура_Key',
      'Характеристика_Key',
      'Склад_Key',
      'ВНаличииBalance',
      'ВРезервеBalance',
      'ВРезервеПодЗаказBalance',
    ],
    conditional: true,
  },
  {
    name: 'Catalog_ВидыЦен',
    kind: 'catalog',
    operations: ['list'],
    fields: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'Code',
      'Description',
      'ИспользоватьПриПродаже',
      'ВалютаЦены_Key',
      'ЦенаВключаетНДС',
    ],
    conditional: false,
  },
  {
    name: 'InformationRegister_ЦеныНоменклатуры',
    kind: 'informationRegister',
    operations: ['sliceLast'],
    fields: ['Period', 'ВидЦены_Key', 'Номенклатура_Key', 'Характеристика_Key', 'Упаковка_Key', 'Цена'],
    conditional: false,
  },
  {
    name: 'Document_УстановкаЦенНоменклатуры',
    kind: 'document',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Number', 'Date', 'Posted'],
    conditional: false,
  },
  {
    name: 'Document_УстановкаЦенНоменклатуры_Товары',
    kind: 'tabularSection',
    operations: ['list'],
    fields: ['Ref_Key'],
    conditional: false,
  },
  {
    name: 'Catalog_СкидкиНаценки',
    kind: 'catalog',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Code', 'Description'],
    conditional: true,
  },
  {
    name: 'Catalog_СоглашенияСКлиентами',
    kind: 'catalog',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Description', 'ВидЦены_Key'],
    conditional: true,
  },
  {
    name: 'Catalog_Партнеры',
    kind: 'catalog',
    operations: ['list'],
    fields: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'Code',
      'Description',
      'НаименованиеПолное',
      'Клиент',
      'ОсновноеСоглашение_Key',
    ],
    conditional: true,
  },
  {
    name: 'Catalog_Партнеры_КонтактнаяИнформация',
    kind: 'tabularSection',
    operations: ['list'],
    fields: ['Ref_Key', 'Тип', 'Вид_Key', 'Представление', 'Значение', 'НомерТелефона', 'НомерТелефонаБезКодов'],
    conditional: true,
  },
  {
    name: 'Catalog_Контрагенты',
    kind: 'catalog',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Code', 'Description', 'Партнер_Key', 'ИНН'],
    conditional: false,
  },
  {
    name: 'Catalog_Контрагенты_КонтактнаяИнформация',
    kind: 'tabularSection',
    operations: ['list'],
    fields: ['Ref_Key', 'Тип', 'Вид_Key', 'Представление', 'Значение', 'НомерТелефона', 'НомерТелефонаБезКодов'],
    conditional: true,
  },
  {
    name: 'AccumulationRegister_РасчетыСКлиентами',
    kind: 'accumulationRegister',
    operations: ['balance'],
    fields: ['Партнер_Key', 'ДолгКлиентаBalance', 'НашДолгBalance'],
    conditional: true,
  },
  {
    name: 'AccumulationRegister_РасчетыСКлиентамиПоСрокам',
    kind: 'accumulationRegister',
    operations: ['balance'],
    fields: ['Партнер_Key'],
    conditional: true,
  },
  {
    name: 'AccumulationRegister_РасчетыСКлиентамиПоДокументам',
    kind: 'accumulationRegister',
    operations: ['balance'],
    fields: ['Партнер_Key'],
    conditional: true,
  },
  {
    name: 'Document_ЗаказКлиента',
    kind: 'document',
    operations: ['list'],
    fields: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'Number',
      'Date',
      'Posted',
      'Статус',
      'Согласован',
      'ДатаОтгрузки',
      'Комментарий',
    ],
    conditional: false,
  },
  {
    name: 'Document_РеализацияТоваровУслуг',
    kind: 'document',
    operations: ['list'],
    fields: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'Number',
      'Date',
      'Posted',
      'Партнер_Key',
      'СуммаДокумента',
      'ЗаказКлиента_Key',
    ],
    conditional: false,
  },
  {
    name: 'Document_РеализацияТоваровУслуг_Товары',
    kind: 'tabularSection',
    operations: ['list'],
    fields: ['Ref_Key'],
    conditional: false,
  },
  {
    name: 'Document_ПриходныйКассовыйОрдер',
    kind: 'document',
    operations: ['list'],
    fields: [
      'Ref_Key',
      'DataVersion',
      'DeletionMark',
      'Number',
      'Date',
      'Posted',
      'Партнер_Key',
      'СуммаДокумента',
      'ХозяйственнаяОперация',
      'СтатьяДДС',
    ],
    conditional: false,
  },
  {
    name: 'Document_ПоступлениеБезналичныхДенежныхСредств',
    kind: 'document',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Number', 'Date', 'Posted', 'Партнер_Key', 'СуммаДокумента'],
    conditional: true,
  },
  {
    name: 'Document_ЭквайринговаяОперация',
    kind: 'document',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Number', 'Date', 'Posted'],
    conditional: true,
  },
  {
    name: 'Document_ВозвратТоваровОтКлиента',
    kind: 'document',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Number', 'Date', 'Posted', 'ДокументОснование'],
    conditional: false,
  },
  {
    name: 'Document_ЗаявкаНаВозвратТоваровОтКлиента',
    kind: 'document',
    operations: ['list'],
    fields: ['Ref_Key', 'DataVersion', 'DeletionMark', 'Number', 'Date', 'Posted'],
    conditional: true,
  },
];
