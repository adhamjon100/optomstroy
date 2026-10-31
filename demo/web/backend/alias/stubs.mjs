// Заглушка пакета `bun` для браузерного бэкенда: адаптер pg-boss fromBunSql импортирует его статически
// (`import { SQL } from 'bun'`), но в браузере этот адаптер не вызывается (backend: 'pglite').
export const SQL = undefined;
export default {};
