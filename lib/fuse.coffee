###
  The "code fusion", generates one working js from commonJs require modules.

  1. supports circular dependency: as long as the source works in nodejs, so should the generated code
  2. original source code is not modified.  Instead code is injected to simulate commonJS require.
  3. recognizes nodejs native components "*.node"
  4. recursive fuse:  fused code can be fused, minified (or not), required and then fused again.

  To learn more, look at generated code.

###
path = require "path"
fs   = require "fs"
_    = require "under_score"

module.exports = fuse = {

  # baseDir: for determining source map original source file location, should be the dir where output file is written
  # moduleName: main module name, module will always be stored in root[moduleName], where root is the root scope
  # units:  array of units
  # asLib:  when false (default), generate code normally: runs the last file in units
  #         when true, generate code that export all detected modules as an object,
  # includePackage: if true, include module's package.json via member 'package', default is false
  # Returns
  # srcCode:  string, the fused source code
  # binaryUnits: array of binary (*.node) modules, to bundle the final executable package do:
  #              copy from <unit.fpath> to <dst_dir>/<unit.key> for unit in binaryUnits
  # sourceMap:  source map content string

  generate : (baseDir, moduleName, units, asLib, includePackage)->
    coreUnits = (unit for unit in units when unit.isCore)
    binaryUnits = (unit for unit in units when unit.isBinary)
    fileUnits = (unit for unit in units when not unit.isCore and not unit.isBinary)

    # for non core untis, figure out a unique key in __m
    fuse.makeKeys(fileUnits.concat(binaryUnits));
    unit.key = unit.fpath for unit in coreUnits # core units: key = fpath

    # store the core modules (aka nodejs modules) in the global module map

    sCoreRequires =
      ("""
      __m['#{unit.key}'] = {
        sts  : 1,
        mod  : {exports: __m.__sr('#{unit.key}')}
      };
      """ for unit in coreUnits).join('\n')

    do=>
      mem = {}
      for unit in binaryUnits
        binName = path.basename(unit.fpath)
        (binName = '_' + binName) while binName in mem # ensure no dup
        unit.binName = binName
        sCoreRequires += """
        __m['#{unit.key}'] = {
          sts  : 1,
          mod  : {exports: __m.__sr('./#{binName}')}
        };
        """

    code = """
      (function(run, root) {
        var ret = run.bind(root)();
        if ('#{moduleName}') root['#{moduleName}'] = ret;
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
      #{sCoreRequires}
      """

    # [_\w\-\.\~], see RFC3986, section 2.3.
    smRegex = /\/\/# sourceMappingURL=([_\w\-\.\~]+)/
    for unit,i in fileUnits
      i = i + 1 # rebase to 1
      smMatch = smRegex.exec(unit.src)
      if (smMatch)
        src = unit.src.replace("//# sourceMappingURL=", "// sourceMappingURL=")
        unit.sm = { url: smMatch[1] }
      else
        src = unit.src

      if path.extname(unit.fpath) == ".json"
        code += """
          __m['#{unit.key}'] = {
            sts: 1,
            mod: { exports:
          """
        if (unit.sm) then unit.sm.line = fuse._lc(code)
        code += src
        code += "}};\n"
      else
        lmapcode = ("        '#{r.node.arguments[0].value}': '#{r.unit.key}'" for r in unit.requires).join(",\n")
        pkginfo = if unit.package then "#{unit.package.name}@#{unit.package.version or ''}" else ""
        code += """
          __m['#{unit.key}'] = {
            sts: null,
            mod: { #{if unit.package and includePackage then "package: #{JSON.stringify(unit.package)}," else ""}
              exports: {} },
            load: (function() {
              var module = __m['#{unit.key}'].mod;
              var exports = module.exports;
              var require = function(name) {
                var namemap = {
          #{lmapcode}
                }
                var k = namemap[name];
                return k ? __m.__r(k) : __m.__sr(name);
              }
              require.resolve = __m.__sr.resolve;
              __m['#{unit.key}'].sts = 0;
          //******** begin #{unit.key} module: #{pkginfo} ************\n
          """
        if (unit.sm) then unit.sm.line = fuse._lc(code) # keep track of line for sourcemap
        code += src
        code += """
          //******** end #{unit.key} module: #{pkginfo}************
              __m['#{unit.key}'].sts = 1;
            }).bind(this)
          };\n
          """
    # seal the code
    if asLib
      code += "return {\n"
      packages = {}
      for unit in fileUnits when unit.package
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
        code += "'#{key}':  __m.__r('#{unit.key}'),\n"
      code += "};\n";
    else
      code += "\nreturn __m.__r('#{_(fileUnits).last().key}');\n";
    code += "\n},this));"

    [code, binaryUnits, fuse.generateSourceMap(baseDir, code, fileUnits)]

  # see https://docs.google.com/document/d/1U1RGAehQwRypUTovF1KRlpiOFze0b-_2gc6fAH0KY0k/edit?pli=1#
  # section "supporting post processing"
  # baseDir:  the original src file location will be calculated relative to baseDir
  generateSourceMap : (baseDir, code, units)->
    sections = []
    for unit in units when unit.sm
      unitDir = path.dirname(unit.fpath)
      # really should support http, https, etc...
      url = path.resolve(unitDir, unit.sm.url)
      try
        sm = JSON.parse(fs.readFileSync(url))
      catch e
        console.log "Invalid source map file #{path.relative(baseDir,url)}, skipping source map generating"
        return null

      # if sm itself consists of concatenated sections, merge them
      if (sm.sections)
        for sec,i in (sm.sections or [])
          sec.offset.line += unit.sm.line
          for s,i in sec.map.sources
            sp = path.resolve(unitDir, (sm.sourceRoot || '') + s)
            sec.map.sources[i] = path.relative(baseDir, sp)
        sections.push sm.sections...
      else
        # concatenate sources into sections, with path resolved
        for s,i in sm.sources
          sp = path.resolve(unitDir, (sm.sourceRoot || '') + s)
          sm.sources[i] = path.relative(baseDir, sp)
        sections.push {
          offset: {line : unit.sm.line, column : 0},
          map : sm
        }
      # sm with a mixture of sources and sections are not supported, doesn't make sense anyway

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
      unit.key = unit.fpath[pfix.length..].replace(/\\/g, '/')

};
