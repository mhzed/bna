var log = require("./log");

// a particular convoluted circular examples where:
// c requires b requires a
// a requires both b and c

var B = require("./b.js");
var C = require("./c.js");
var b = new B();
var c = new C();

log.push(b)
log.push(c);

// two B are created as result
log.push(B === C.super);         // false
log.push(b instanceof B);        // true
log.push(b instanceof C.super);  // false

module.exports = log;