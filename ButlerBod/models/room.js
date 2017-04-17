
//Based on https://docs.microsoft.com/en-us/azure/app-service-web/storage-nodejs-use-table-storage-web-site
var azure = require('azure-storage');
var uuid = require('node-uuid');
var entityGen = azure.TableUtilities.entityGenerator;

module.exports = Room;

function Room(storageClient, tableName, partitionKey) {
    this.storageClient = storageClient;
    this.tableName = tableName;
    this.partitionKey = partitionKey;
    this.storageClient.createTableIfNotExists(tableName, function tableCreated(error) {
        if(error) {
            throw error;
        }
    } );
};

Room.prototype = {
    find: function(query, callback) {
        self = this;
        self.storageClient.queryEntities(this.tableName, query, null, function entitiesQueried(error, result) {
            if(error) {
                callback(error);
            } else {
                callback(null, result.entries);
            }
        });
    },

    addItem: function(item, callback) {
        self = this;
        var itemDescriptor = {
            PartitionKey: entityGen.String(self.partitionKey),
            RowKey: entityGen.String(uuid()),
            name: entityGen.String(item.name),
            note: entityGen.String(item.note)
        };
        self.storageClient.insertEntity(self.tableName, itemDescriptor, function entityInserted(error) {
            if(error) {
                callback(error);
            }
            callback(null);
        });
    },

    getItem: function(rKey, callback) {
        self = this;
        self.storageClient.retrieveEntity(self.tableName, self.partitionKey, rKey, function entityQueried(error, entity) {
            if(error) {
                callback(error);
            } else {
                callback(null, result);
            }
        });
    },

    updateItem: function(rKey, item, callback) {
        self = this;
        self.storageClient.retrieveEntity(self.tableName, self.partitionKey, rKey, function entityQueried(error, entity) {
            if(error) {
                callback(error);
            }
            entity.name = entityGen.String(item.name);
            entity.note = entityGen.String(item.note);

            self.storageClient.updateEntity(self.tableName, entity, function entityUpdated(error) {
                if(error) {
                    calbback(error);
                }
                callback(null);
            });
        });
    }
}
