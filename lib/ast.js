let ast;
const _ = require("underscore");


// esprima ast manipulation helpers,

module.exports = (ast = {
  /*
    filters: an array of filter functions
    example:
    ast.traverse esprima.parse(src, opt), (node)->
  */
  traverse(node, filters, cb){
    let filter;
    if (_(filters).isFunction()) {
      cb = filters;
      filters = [];
    }
    if (filters.length === 0) {
      filter = node=> true;
    } else {
      filter = node=> ( Array.from(filters).filter((f) => f(node)).map((f) => f)).length > 0;
    }
    return ast._traverse(node, filter, cb);
  },

  _traverse(node, filter, cb){

    let n;
    if (Array.isArray(node)) {
      return (() => {
        const result = [];
        for (n of Array.from(node)) {
          result.push(ast._traverse(n, filter, cb));
        }
        return result;
      })();
    } else if (node && (typeof node === 'object')) {
      if (filter(node)) { cb(node); }
      return (() => {
        const result1 = [];
        for (let key in node) {
          n = node[key];
          if (n) {
            result1.push(ast._traverse(n, filter, cb));
          }
        }
        return result1;
      })();
    } else {
      if (filter(node)) { return cb(node); }
    }
  }
  ,

  isFunc(node, name){   // name: function name, optional
    return node && node.callee 
      && (node.type === 'CallExpression') 
      && (node.callee.type === 'Identifier') 
      && ( (!name) || (node.callee.name === name));
  }
  ,

  isRequire(node){
    return ast.isFunc(node, 'require');
  }
  ,



});