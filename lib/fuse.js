/*
  The "code fusion", generates one working js from commonJs require modules.

  1. supports circular dependency: as long as the source works in nodejs, so should the generated code
  2. original source code is not modified.  Instead code is injected to simulate commonJS require.
  3. recognizes nodejs native components "*.node"
  4. recursive fuse:  fused code can be fused, minified (or not), required and then fused again.

  To learn more, look at generated code.

*/
let fuse;
const path = require("path");
const fs   = require("fs");
const _ = require("underscore");
const log = require("lawg");
const sourceMap = require("source-map");

module.exports = (fuse = {

  // baseDir: where output file is at, for determining source map original source file location
  // moduleName: main module name, module will always be stored in root[moduleName], where root is the root scope
  // units:  array of units
  // asLib:  when false (default), generate code normally: runs the last file in units
  //         when true, generate code that export all detected modules as an object,
  // includePackage: if true, include module's package.json via member 'package', default is false
  // prependCode: code to put at the top of the fused file

  // Returns
  // srcCode:  string, the fused source code
  // binaryUnits: array of binary (*.node) modules, to bundle the final executable package do:
  //              copy from <unit.fpath> to <dst_dir>/<unit.key> for unit in binaryUnits
  // sourceMap:  source map content string

  generate({baseDir, moduleName, units, asLib, generateSm, includePackage, prependCode}){
    let key, unit;
    const coreUnits = ((() => {
      const result = [];
      for (unit of Array.from(units)) {         if (unit.isCore) {
          result.push(unit);
        }
      }
      return result;
    })());
    const binaryUnits = ((() => {
      const result1 = [];
      for (unit of Array.from(units)) {         if (unit.isBinary) {
          result1.push(unit);
        }
      }
      return result1;
    })());
    const fileUnits = ((() => {
      const result2 = [];
      for (unit of Array.from(units)) {         if (!unit.isCore && !unit.isBinary) {
          result2.push(unit);
        }
      }
      return result2;
    })());

    // for non core untis, figure out a unique key in __m
    fuse._makeKeys(fileUnits.concat(binaryUnits));
    for (unit of Array.from(coreUnits)) { unit.key = unit.fpath; } // core units: key = fpath

    // store the core modules (aka nodejs modules) in the global module map

    let sCoreRequires =
      ((() => {
        const result3 = [];
        for (unit of Array.from(coreUnits)) {           result3.push(`\
__m['${unit.key}'] = {
      sts  : 1,
      mod  : {exports: __m.__sr('${unit.key}')}
};\
`);
        }
        return result3;
      })()).join('\n');

    (() => {
      const mem = {};
      return (() => {
        const result4 = [];
        for (unit of Array.from(binaryUnits)) {
          let binName = path.basename(unit.fpath);
          while (Array.from(mem).includes(binName)) { binName = `_${binName}`; } // ensure no dup
          unit.binName = binName;
          result4.push(sCoreRequires += `\
__m['${unit.key}'] = {
    sts  : null,
    mod  : {exports: {}},
    load : function() { return (__m['${unit.key}'].mod.exports = __m.__sr('./${binName}')); }
};\
`);
        }
        return result4;
      })();
    })();

    let code = `\
${prependCode}
(function(run, root) {
  var ret = run.bind(root)();
  if ('${moduleName}') root['${moduleName}'] = ret;
  if ("object" == typeof exports && "undefined" != typeof module)
    module.exports = ret;
}(function() {
var __m = {};
if (typeof require === 'undefined') __m.__sr = function() {};
else __m.__sr = require;
__m.__r = function(key) {
  var m = __m[key];
  if (m.sts === null) m.load.call();
  return m.mod.exports;
};
${sCoreRequires}\
`;

    // [_\w\-\.\~], see RFC3986, section 2.3.
    const smRegex = /\/\/# sourceMappingURL=([_\w\-\.\~]+)/;
    for (let i = 0; i < fileUnits.length; i++) {
      var src;
      unit = fileUnits[i];
      const smMatch = smRegex.exec(unit.src);
      if (smMatch) {
        unit.src = (src = unit.src.replace("//# sourceMappingURL=", "// sourceMappingURL="));
        unit.sm = { url: smMatch[1] };
      } else {
        ({ src } = unit);
      }

      if (path.extname(unit.fpath) === ".json") {
        code += `\
__m['${unit.key}'] = {
  sts: 1,
  mod: { exports:\
`;
        if (generateSm) { unit.smline = fuse._lc(code); }
        code += src;
        code += "}};\n";
      } else {
        const lmapcode = (Array.from(unit.requires).map((r) => `        '${r.name}': '${r.unit.key}'`)).join(",\n");
        let pkginfo = unit.package ? `${unit.package.name}@${unit.package.version || ''}` : "";
        pkginfo += `(${path.basename(unit.fpath)})`;
        code += `\
__m['${unit.key}'] = {
  sts: null,
  mod: { ${unit.package && includePackage ? `package: ${JSON.stringify(unit.package)},` : ""}
    exports: {} },
  load: (function() {
    var module = __m['${unit.key}'].mod;
    var exports = module.exports;
    var require = function(name) {
      var namemap = {
${lmapcode}
      }
      var k = namemap[name];
      return k ? __m.__r(k) : __m.__sr(name);
    }
    require.resolve = __m.__sr.resolve;
    __m['${unit.key}'].sts = 0;
//******** begin file ${pkginfo} ************\n\
`;
        if (generateSm) { unit.smline = fuse._lc(code); }
        code += src;
        code += `\

//******** end file ${pkginfo}************
    __m['${unit.key}'].sts = 1;
  }).bind(this)
};\n\
`;
      }
    }
    // seal the code
    if (asLib) {
      code += "return {\n";
      const packages = {};
      for (unit of Array.from(fileUnits)) {
        if (unit.package) {
          if (unit.package.name in packages) {
            // key-ed by package name, therefore must resolve conflicting version by appending version
            // to package name for the name of the key
            const oldunit = packages[unit.package.name];
            if (oldunit.package.version !== unit.package.version) {
              packages[`${oldunit.package.name}@${oldunit.package.version}`] = oldunit;
              packages[`${unit.package.name}@${unit.package.version}`] = unit;
            }
          } else {
            packages[unit.package.name] = unit;
          }
        }
      }

      for (key in packages) {
        unit = packages[key];
        code += `'${key}':  __m.__r('${unit.key}'),\n`;
      }
      code += "};\n";
    } else {
      code += `\nreturn __m.__r('${_(fileUnits).last().key}');\n`;
    }
    code += "\n},this));";

    return [code, binaryUnits, generateSm ? fuse._generateSourceMap(baseDir, code, fileUnits) : null];
  },


  // see https://docs.google.com/document/d/1U1RGAehQwRypUTovF1KRlpiOFze0b-_2gc6fAH0KY0k/edit?pli=1#
  // section "supporting post processing"
  // baseDir:  the original src file location will be calculated relative to baseDir
  _generateSourceMap(baseDir, code, units){
    const sections = [];
    for (let unit of Array.from(units)) {
      const unitDir = path.dirname(unit.fpath);
      if (unit.sm) {
        // TODO: should support http, https, etc...
        var i, s, sm, sp;
        const url = path.resolve(unitDir, unit.sm.url);
        try {
          sm = JSON.parse(fs.readFileSync(url));
        } catch (e) {
          log(`Skipped invalid source map file ${path.relative(baseDir,url)}`);
          continue;
        }

        // if sm itself consists of concatenated sections, merge them
        if (sm.sections) {
          const iterable = sm.sections || [];
          for (i = 0; i < iterable.length; i++) {
            const sec = iterable[i];
            sec.offset.line += unit.smline;
            for (i = 0; i < sec.map.sources.length; i++) {
              s = sec.map.sources[i];
              sp = path.resolve(unitDir,  s);
              sec.map.sources[i] = path.relative(baseDir, sp);
            }
          }
          sections.push(...Array.from(sm.sections || []));
        } else {
          // concatenate sources into sections, with path resolved
          for (i = 0; i < sm.sources.length; i++) {
            s = sm.sources[i];
            sp = path.resolve(unitDir, s);
            sm.sources[i] = path.relative(baseDir, sp);
          }
          sections.push({
            offset: {line : unit.smline, column : 0},
            map : sm
          });
        }
      } else { // js file has no matching source map file, generate it
        var line;
        const { SourceMapGenerator } = sourceMap;
        const srcfile = path.relative(baseDir, unit.fpath);
        const map = new SourceMapGenerator({file:srcfile});
        const lc = fuse._lc(unit.src);
        if (lc > 0) {
          for (line = 1, end = lc, asc = 1 <= end; asc ? line <= end : line >= end; asc ? line++ : line--) {   // 1 to 1 mapping for each line
            var asc, end;
            map.addMapping({
              source: srcfile,
              original : {line, column:0},
              generated : {line, column:0}
            });
          }
        }
        sections.push({
          offset: {line: unit.smline, column: 0},
          map: map.toJSON()
        });
      }
    }
    return sections.length === 0 ? null : {
      version : 3,
      file : '',
      sections
    };
  },

  _lc(str) {
    let c = 0;
    for (let i = 0, end = str.length, asc = 0 <= end; asc ? i < end : i > end; asc ? i++ : i--) {
      if (str[i] === '\n') {
        c++;
      }
    }
    return c;
  },

  _makeKeys(units){
    // make unique key from i (offset in array)
    const c = i=>
      (__range__(0, Math.floor(i/26), true).map((x) => i%26)).reduce(
        (r,j)=> r+String.fromCharCode('a'.charCodeAt(0)+j)
      , '')
    ;
    return (() => {
      const result = [];
      for (let i = 0; i < units.length; i++) {
        const unit = units[i];
        result.push(unit.key = c(i));
      }
      return result;
    })();
  },

  _makeSensibleKeys(units){
    // make terse unique keys for each file units: essentially just remove the common prefix from units.fpath
    const commonPrefix = function(s1, s2) {
      let i;
      for (i = 0, end = Math.min(s1.length, s2.length), asc = 0 <= end; asc ? i < end : i > end; asc ? i++ : i--) { var asc, end;
      if (s1[i] !== s2[i]) { break; } }
      return s1.length < s2.length ? s1.slice(0, i) : s2.slice(0, i);
    };
    let pfix = (units.slice(1).reduce(((pfix, unit) => commonPrefix(pfix, unit.fpath)), units[0].fpath));
    pfix = pfix.replace(/[^\/\\]*$/, '');  // trim trail non-path dividefix
    return (() => {
      const result = [];
      for (let unit of Array.from(units)) {
        result.push(unit.key = unit.fpath.slice(pfix.length).replace(/\\/g, '/'));
      }
      return result;
    })();
  }


});

function __range__(left, right, inclusive) {
  let range = [];
  let ascending = left < right;
  let end = !inclusive ? right : ascending ? right + 1 : right - 1;
  for (let i = left; ascending ? i < end : i > end; ascending ? i++ : i--) {
    range.push(i);
  }
  return range;
}