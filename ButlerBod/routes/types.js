var azure = require('azure-storage');
var async = require('async');

module.exports = Types;

function Types(type) {
    this.type = type;
}

Types.prototype = {
    showTypes: function(req, res) {
        self = this;
        var query = new azure.TableQuery();
        self.type.find(query, function itemsFound(error, items) {
            res.render('types', {title: 'Type List', Types: items});
        });
    },

    addType: function(req, res) {
        var self = this;
        var item = req.body.item;
        self.type.addItem(item, function itemAdded(error) {
            if(error) {
                throw error;
            }
            res.redirect('/types');
        });
    },

    updateType: function(req, res) {
        var self = this;
        var updatedtype = req.body.item;
        self.type.updateItem(item, function itemUpdated(error) {
            if(error) {
                throw error;
            } 
            res.redirect('/types');
        });
    }
}
/*
completeTask: function(req,res) {
     var self = this;
     var completedTasks = Object.keys(req.body);
     async.forEach(completedTasks, function taskIterator(completedTask, callback) {
       self.task.updateItem(completedTask, function itemsUpdated(error) {
         if(error){
           callback(error);
         } else {
           callback(null);
         }
       });
     }, function goHome(error){
       if(error) {
         throw error;
       } else {
        res.redirect('/');
       }
     });
   }
   */