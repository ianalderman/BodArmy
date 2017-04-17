var azure = require('azure-storage');
var async = require('async');

module.exports = Rooms;

function Rooms(room) {
    this.room = room;
}

Rooms.prototype = {
    showRooms: function(req, res) {
        self = this;
        var query = new azure.TableQuery();
        self.room.find(query, function itemsFound(error, items) {
            res.render('rooms', {title: 'Room List', rooms: items});
        });
    },

    addRoom: function(req, res) {
        var self = this;
        var item = req.body.item;
        self.room.addItem(item, function itemAdded(error) {
            if(error) {
                throw error;
            }
            res.redirect('/rooms');
        });
    },

    updateRoom: function(req, res) {
        var self = this;
        var updatedRoom = req.body.item;
        self.room.updateItem(item, function itemUpdated(error) {
            if(error) {
                throw error;
            } 
            res.redirect('/rooms');
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