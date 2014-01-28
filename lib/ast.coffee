_ = require "under_score"

# esprima ast manipulation helpers,
module.exports = ast = {
  ###
    filters: an array of filter functions
    example:
    ast.traverse esprima.parse(src, opt), (node)->
  ###
  traverse : (node, filters, cb)->
    if _(filters).isFunction()
      cb = filters
      filters = []
    if (filters.length == 0)
      filter = (node)->true
    else
      filter = (node)->
        ( f for f in filters when f(node)).length > 0
    ast._traverse(node, filter, cb)

  _traverse : (node, filter, cb)->

    if (Array.isArray(node))
      for n in node
        ast._traverse(n, filter, cb)
    else if (node && typeof node == 'object')
      if (filter(node)) then cb(node);
      for key,n of node when n
        ast._traverse(n, filter, cb);
    else
      if (filter(node)) then cb(node)
  ,

  isFunc : (node, name)->   # name: function name, optional
    node && node.callee \
      && node.type == 'CallExpression' \
      && node.callee.type == 'Identifier' \
      && ( (not name) or node.callee.name == name)
  ,

  isRequire : (node)->
    ast.isFunc(node, 'require')
  ,



}