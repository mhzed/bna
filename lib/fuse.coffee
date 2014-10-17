###
  The "code fusion", generates one working js from commonJs require modules.

  1. supports circular dependency: as long as the source works in nodejs, so should the generated code
  2. original source code is not modified.  Instead code is injected to simulate commonJS require.
  3. handles nodejs native components "*.node"

  To learn more, you are encouraged to look at generated code.

###
path = require "path"
fs   = require "fs"
_    = require "under_score"

module.exports = bigcat = {

  # baseDir: for determining source map original source file location, should be the dir where output file is written
  # moduleName: main module name, code is sealed with this.moduleName = ....
  # units:  array of jnits
  # aslib:  when false (default), generate code normally: runs the last file in units
  #         when true, generate code that export all detected modules as a map,
  # the main api, returns [srcCode, binaryUnits]
  # srcCode:  string, the fused source code
  # binaryUnits: array of binary (*.node) modules, to bundle the final executable package do:
  #              copy from <unit.fpath> to <dst_dir>/<unit.key> for unit in binaryUnits
  # includePackage: if true, include module's package.json via member 'package', default is false
  generate : (baseDir, moduleName, units, aslib, includePackage)->
    coreunits = (unit for unit in units when unit.isCore)
    binaryUnits = (unit for unit in units when unit.isBinary)
    fileunits = (unit for unit in units when not (unit.isCore)) # includes binunits

    # for non core untis, figure out a unique key in __m
    bigcat.makeKeys(fileunits);
    unit.key = unit.fpath for unit in coreunits # core units: key = fpath

    # store the core modules (aka nodejs modules) in the global module map
    sCoreRequires =
      ("""
      __m["#{unit.key}"] = {
        status  : "loaded",
        module  : {exports: __m.__builtin_require('#{unit.key}')}
      };
      """ for unit in coreunits.concat(binaryUnits)).join('\n')

    code =
      """
      (function(run) {
        if ("object" == typeof exports && "undefined" != typeof module)
          module.exports = run();
        else if ("undefined" != typeof window)
          window.#{moduleName} = run();
        else if ("undefined" != typeof self) {
          self.#{moduleName} = run();
        }
        // else if ("function" == typeof define && define.amd) // AMD not supported yet
        // else  unknown runtime, do nothing
      }(function() {
      var __m = {};
      if (typeof require === 'undefined')
        __m.__builtin_require = function() {};
      else
        __m.__builtin_require = require;
      __m.__require = function(key) {
        var m = __m[key];
        if (m.status === null)
          m.loader.call();
        return m.module.exports;
      };
      #{sCoreRequires}

      """

    # [_\w\-\.\~], see RFC3986, section 2.3.
    smRegex = /\/\/# sourceMappingURL=([_\w\-\.\~]+)/
    for unit,i in fileunits
      i = i + 1 # rebase to 1
      smMatch = smRegex.exec(unit.src)
      if (smMatch)
        src = unit.src.replace("//# sourceMappingURL=", "// sourceMappingURL=")
        unit.sm = { url: smMatch[1] }
      else
        src = unit.src

      if path.extname(unit.fpath) == ".json"
        code +=
          """
          __m["#{unit.key}"] = {
            status: "loaded",
            module: { exports:

          """
        if (unit.sm) then unit.sm.line = bitcat._lc(code)
        code += src
        code +=
          """
            }
          };

          """
      else
        lmapcode = ("        '#{r.node.arguments[0].value}': '#{r.unit.key}'" for r in unit.requires).join(",\n")
        pkginfo = if unit.package then "#{unit.package.name}@#{unit.package.version or ''}" else ""
        code +=
          """
          __m["#{unit.key}"] = {
            status: null,
            module: { #{if unit.package and includePackage then "package: #{JSON.stringify(unit.package)}," else ""}
              exports: {} },
            loader: (function() {
              var module = __m["#{unit.key}"].module;
              var exports = module.exports;
              var require = function(name) {
                var namemap = {
          #{lmapcode}
                }
                var k = namemap[name];
                return k ? __m.__require(k) : __m.__builtin_require(name);
              }
              if (__m.__builtin_require) require.resolve = __m.__builtin_require.resolve;
              __m["#{unit.key}"].status = 'loading';
          //******** begin #{unit.key} module: #{pkginfo} ************

          """
        if (unit.sm) then unit.sm.line = bigcat._lc(code)
        code += src
        code +=
          """
          //******** end #{unit.key} module: #{pkginfo}************
              __m["#{unit.key}"].status = 'loaded';
            }).bind(this)
          };

          """
    # seal the code
    if aslib
      code += "return {\n"
      packages = {}
      for unit in fileunits when unit.package
        if unit.package.name of packages
          # key-ed by package name, therefore must resolve conficting version by appending version
          # to package name for the name of the key
          oldunit = packages[unit.package.name]
          if (oldunit.package.version != unit.package.version)
            packages["#{oldunit.package.name}@#{oldunit.package.version}"] = oldunit
            packages["#{unit.package.name}@#{unit.package.version}"] = unit
        else
          packages[unit.package.name] = unit

      for key,unit of packages
        code += "'#{key}':  __m.__require('#{unit.key}'),\n"
      code += "};\n";
    else
      code +=
        """
        return __m.__require("#{_(fileunits).last().key}");\n
        """
    code +=
      """
        }));
      """

    [code, binaryUnits, bigcat.generateSourceMap(baseDir, code, fileunits)]

  # see https://docs.google.com/document/d/1U1RGAehQwRypUTovF1KRlpiOFze0b-_2gc6fAH0KY0k/edit?pli=1#
  # section "supporting post processing"
  # baseDir:  the original src file location will be calculated relative to baseDir
  generateSourceMap : (baseDir, code, units)->
    sections = []
    for unit in units when unit.sm
      unitDir = path.dirname(unit.fpath)
      # really should support http, https, etc...
      url = path.resolve(unitDir, unit.sm.url)
      sm = JSON.parse(fs.readFileSync(url))

      for s,i in sm.sources
        sp = path.resolve(unitDir, (sm.sourceRoot || '') + s)
        sm.sources[i] = path.relative(baseDir, sp)
      sections.push {
        offset: {line : unit.sm.line, column : 0},
        map : sm
      }
    return if sections.length == 0 then null else {
      version : 3,
      file : '',
      sections
    }


  _lc : (str) ->
    c = 0
    for i in [0...str.length] when str[i] == '\n'
      c++
    c

  # make terse unique keys for each file units: essentially just remove the common prefix from units.fpath
  makeKeys : (units)->
    commonPrefix = (s1, s2) ->
      for i in [0...Math.min(s1.length, s2.length)] when s1[i] != s2[i] then break
      return if s1.length < s2.length then s1[0...i] else s2[0...i]
    pfix = (units[1..].reduce ((pfix, unit) -> commonPrefix(pfix, unit.fpath)), units[0].fpath)
    pfix = pfix.replace(/[^\/\\]*$/, '')  # trim trail non-path dividers

    for unit in units
      unit.key = unit.fpath[pfix.length..]

};
