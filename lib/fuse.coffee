###
  The "code fusion", generates one working js from commonJs require modules.

  1. supports circular dependency: as long as the source works in nodejs, so should the generated code
  2. original source code is not modified.  Instead code is injected to simulate commonJS require.
  3. handles nodejs native components "*.node"

  To learn more, you are encouraged to look at generated code.

###
path = require "path"
_    = require "under_score"

module.exports = bigcat = {

  # moduleName: main module name, code is sealed with this.moduleName = ....
  # units:  array of jnits
  # aslib:  when false (default), generate code normally: runs the last file in units
  #         when true, generate code that export all detected modules as a map,
  # the main api, returns [srcCode, binaryUnits]
  # srcCode:  string, the fused source code
  # binaryUnits: array of binary (*.node) modules, to bundle the final executable package do:
  #              copy from <unit.fpath> to <dst_dir>/<unit.key> for unit in binaryUnits
  generate : (moduleName, units, aslib)->
    coreunits = (unit for unit in units when unit.isCore)
    binunits = (unit for unit in units when unit.isBinary)
    fileunits = (unit for unit in units when not (unit.isCore)) # includes binunits

    # for non core untis, figure out a unique key in __m
    bigcat.makeKeys(fileunits);
    unit.key = unit.fpath for unit in coreunits # core units: key = fpath

    # store the core modules in the global module map
    sCoreRequires =
      ("""
      __m["#{unit.key}"] = {
        status  : "loaded",
        module  : {exports: __m.__builtin_require('#{unit.key}')}
      };
      """ for unit in coreunits.concat(binunits)).join('\n')

    code =
      """
      this.#{moduleName} = (function() {

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

    for unit,i in fileunits
      i = i + 1 # rebase to 1
      if path.extname(unit.fpath) == ".json"
        code +=
          """
          __m["#{unit.key}"] = {
            status: "loaded",
            module: { exports: #{unit.src} }
          };

          """
      else
        lmapcode = ("        '#{r.node.arguments[0].value}': '#{r.unit.key}'" for r in unit.requires).join(",\n")
        pkginfo = if unit.package then "#{unit.package.name}@#{unit.package.version or ''}" else ""
        code +=
        """
        __m["#{unit.key}"] = {
          status: null,
          module: { #{if unit.package then "package: #{JSON.stringify(unit.package)}," else ""}
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
        #{unit.src}
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
        }).call(this);
        if (typeof module !== 'undefined') module.exports = this.#{moduleName};
      """
    [code, binunits]


  # make unique keys for each file units: a substring of file's full path
  makeKeys : (units)->
    # the idea is fpath is always unqiue, so use the string after last "node_modules/" in fpath, if dup is found, then
    # use string after second to last node_modules/, and so on until fpath is returned
    nmpath = (fpath, c)->   # c: 1=>last node_modules/  2: second to last, ...
      marker = 'node_modules/'
      offset = fpath.length;
      while offset != -1 and c-- > 0
        offset = fpath.lastIndexOf(marker, offset-1)
      return if offset == -1 then fpath else fpath.slice(offset + marker.length)

    memory = {}
    for unit in units
      key = ""; c = 1
      while not key or key of memory then key = nmpath(unit.fpath, c++)
      memory[key] = 1
      unit.key = key



};
