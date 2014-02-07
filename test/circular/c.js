var log = require("./log");

module.exports = C;

log.push("c1");
var B = require("./B.js");
log.push("c2");

require("./inherits.js")(C, B);
function C() {
    C.super.call(this);
    this.c = 'c'
}

