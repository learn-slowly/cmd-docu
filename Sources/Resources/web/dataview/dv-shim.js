// cmdALL dataviewjs 실행용 dv API 서브셋 shim (JSContext에서 로드).
// 전제: 전역 luxon, 동기 브릿지 __dvNative.{currentPage,pages,page}(JSON 문자열 반환).
// 렌더 호출은 __dvOutput 배열에 수집되고 네이티브가 HTML로 직렬화한다.
// 지원 범위는 스펙 §3(실사용 서브셋+여유분) — 그 밖은 한국어 에러를 던진다.
(function () {
  'use strict';
  var L = luxon;

  function toDay(s) { return s ? L.DateTime.fromISO(s) : null; }

  function makeLink(path, display) {
    return {
      __dvLink: true, path: path, display: display || null,
      toString: function () { return this.display || this.path; }
    };
  }

  function wrapPage(m) {
    var lists = m.lists.map(function (li) {
      return { text: li.text, header: { subpath: li.headerSubpath },
               tags: li.tags, task: li.task, completed: li.completed };
    });
    var file = {
      name: m.name, folder: m.folder, path: m.path,
      day: toDay(m.day),
      mtime: L.DateTime.fromMillis(m.mtime), ctime: L.DateTime.fromMillis(m.ctime),
      link: makeLink(m.path, m.name),
      tags: m.tags, frontmatter: m.frontmatter,
      lists: lists,
      tasks: lists.filter(function (li) { return li.task; })
    };
    var page = {};
    for (var k in m.frontmatter) page[k] = m.frontmatter[k];   // p.필드명 접근(여유분)
    page.file = file;
    return page;
  }

  function DataArray(values) { this.values = values; }
  DataArray.prototype.where = function (f) { return new DataArray(this.values.filter(f)); };
  DataArray.prototype.filter = DataArray.prototype.where;
  DataArray.prototype.map = function (f) { return new DataArray(this.values.map(f)); };
  DataArray.prototype.forEach = function (f) { this.values.forEach(f); };
  DataArray.prototype.array = function () { return this.values.slice(); };
  // Dataview 시맨틱: sort(키 함수, 'asc'|'desc') — 비교자가 아니라 키 추출.
  DataArray.prototype.sort = function (keyFn, dir) {
    var mul = dir === 'desc' ? -1 : 1;
    var sorted = this.values.slice().sort(function (a, b) {
      var ka = keyFn ? keyFn(a) : a, kb = keyFn ? keyFn(b) : b;
      if (ka < kb) return -mul;
      if (ka > kb) return mul;
      return 0;
    });
    return new DataArray(sorted);
  };
  Object.defineProperty(DataArray.prototype, 'length',
    { get: function () { return this.values.length; } });
  if (typeof Symbol !== 'undefined') {
    DataArray.prototype[Symbol.iterator] = function () { return this.values[Symbol.iterator](); };
  }

  function toArray(x) {
    if (x instanceof DataArray) return x.values;
    if (Array.isArray(x)) return x;
    return x == null ? [] : [x];
  }

  // 셀 정규화: 링크는 마커 유지, luxon 날짜는 ISO 날짜 문자열, 나머지는 문자열.
  function cell(v) {
    if (v && v.__dvLink) return v;
    if (v instanceof DataArray) return toArray(v).map(cell);
    if (Array.isArray(v)) return v.map(cell);
    if (v && v.isLuxonDateTime) return v.toISODate() || v.toISO();
    return v == null ? '' : String(v);
  }

  function parsed(json) {
    var r = JSON.parse(json);
    if (r && r.error) throw new Error(r.error);
    return r;
  }

  globalThis.__dvOutput = [];
  var out = globalThis.__dvOutput;

  function unsupported(name) {
    return function () { throw new Error('cmdALL은 ' + name + '을(를) 지원하지 않습니다'); };
  }

  globalThis.dv = {
    luxon: L,
    current: function () { return wrapPage(parsed(__dvNative.currentPage())); },
    pages: function (source) {
      return new DataArray(parsed(__dvNative.pages(source == null ? '' : String(source))).map(wrapPage));
    },
    page: function (path) {
      var j = __dvNative.page(String(path));
      return j ? wrapPage(parsed(j)) : null;
    },
    // 옵시디언 Dataview 시맨틱: 연-월-일이 명시된 문자열만 날짜로 취급한다.
    // luxon fromISO를 그대로 쓰면 "2026-W27"(ISO 주)·"2026-07"(연-월)까지 파싱돼
    // 주간 표에 위클리·먼슬리 노트가 빈 행으로 끼어든다(실측 결함).
    // 주의: 시간 성분은 버려진다 — 실사용 블록은 날짜 비교뿐이라 무영향.
    date: function (s) {
      if (s == null) return null;
      if (s.isLuxonDateTime) return s;
      var m = String(s).match(/\d{4}-\d{2}-\d{2}/);
      return m ? L.DateTime.fromISO(m[0]) : null;
    },
    fileLink: function (path, _embed, display) { return makeLink(path, display); },
    table: function (headers, rows) {
      out.push({ type: 'table', headers: toArray(headers).map(cell),
                 rows: toArray(rows).map(function (r) { return toArray(r).map(cell); }) });
    },
    list: function (items) { out.push({ type: 'list', items: toArray(items).map(cell) }); },
    paragraph: function (t) { out.push({ type: 'paragraph', text: cell(t) }); },
    header: function (level, t) { out.push({ type: 'header', level: Number(level) || 1, text: cell(t) }); },
    span: function (t) { out.push({ type: 'span', text: cell(t) }); },
    el: unsupported('dv.el(DOM 조작)'),
    view: unsupported('dv.view(외부 스크립트)'),
    query: unsupported('dv.query(DQL)'),
    tryQuery: unsupported('dv.tryQuery(DQL)'),
    io: { load: unsupported('dv.io'), csv: unsupported('dv.io') }
  };
})();
