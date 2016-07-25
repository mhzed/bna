var log = require("./log");

module.exports = C;

log.push("c1");
var B = require("./b.js");
log.push("c2");

require("./inherits.js")(C, B);
function C() {
    B.call(this);
    this.c = 'c'
}

